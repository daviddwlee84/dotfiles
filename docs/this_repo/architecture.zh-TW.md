# 儲存庫架構與安裝流程

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`chezmoi apply` 如何在這台機器上部署設定檔，並觸發 ansible / brew 的執行。

## 目錄結構 (Layout)

```
chezmoi repo/
├── dot_* files               → ~/.* (config files)
├── dot_ansible/              → ~/.ansible/ (ansible playbooks)
├── run_once_before_*.tmpl    → bootstrap (runs once)
└── run_onchange_after_*.tmpl → ansible (runs on changes)
```

## 安裝順序 (Install order)

1. **Bootstrap** (`run_once_before`) — 安裝 Homebrew (macOS/Linux)、`uv`、`ansible`、`mise`。
2. **`chezmoi apply`** — 部署設定檔與 ansible 劇本 (playbook)。
3. **Ansible** (`run_onchange_after`) — 在全新安裝以及角色 (role) 變更時執行。
4. **Brew bundle** (`run_onchange_after`) — 啟用時安裝 GUI 應用程式。

## 自動執行腳本 (Auto-run scripts)

| 腳本 | 行為 |
|--------|----------|
| `run_once_before_00_bootstrap.sh.tmpl` | 安裝 Homebrew (macOS 與 Linux)、`uv`、`mise`、`ansible` |
| `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` | 以全部 tag 執行 ansible |
| `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` | 執行 `brew bundle`（若 `installBrewApps` 啟用，或在 macOS 上若 `installAiDesktopApps` 啟用） |

`onchange` 腳本會包含所有角色檔案的 SHA256 雜湊值。它會在**全新安裝**（沒有先前的雜湊狀態）以及**更新**（任一角色的 `tasks/main.yml` 或 `defaults/main.yml` 變更）時執行。

若要強制重新執行所有腳本：

```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

關於三個 run-script 共用的 sudo 快取，請參閱 [sudo-session.md](sudo-session.md)。

## 外部資源 (Externals) (`.chezmoiexternal.toml.tmpl`)

過去由 Ansible 進行 clone 的上游 git 儲存庫 / 單一檔案下載，現在改在儲存庫根目錄的 `.chezmoiexternal.toml.tmpl` 宣告。`chezmoi` 會在 `chezmoi apply` 期間抓取這些資源，並每週重新拉取一次（`refreshPeriod = "168h"`）：

- oh-my-zsh 核心 + 4 個自訂外掛 (`zsh-autosuggestions`、`zsh-syntax-highlighting`、`zsh-completions`、`zsh-vi-mode`)
- TPM (tmux plugin manager，`~/.tmux/plugins/tpm`)
- fzf git 來源（僅 Linux，`~/.fzf`；apt 版本沒有 `--zsh`）
- toolkami.rb (`~/.local/share/toolkami/toolkami.rb`)

```bash
chezmoi apply                          # normal: pull if older than 168h
chezmoi apply --refresh-externals      # force: pull every external now
```

Ansible 只保留 `externals` 無法處理的「clone 之後」步驟：

- `zsh` 角色 — 安裝 `zsh` 套件 + 變更登入 shell。
- `devtools` 角色 — 執行 `tpm/bin/install_plugins` 一次（哨兵檔 (sentinel)：`~/.tmux/plugins/.ansible-installed`）。
- `lazyvim_deps` 角色 — 執行 `~/.fzf/install --bin`（透過 `creates:` 達成冪等 (idempotent)）。

**何時應加進這裡，何時應放在 Ansible**：當內容只是純粹的 clone / 單一檔案，且唯一條件是 `.chezmoi.os` 時，使用 `.chezmoiexternal`。若需要架構 (arch)、`noRoot`、`armv7l` 邏輯、動態版本路徑或 `become: true`，則保留在 Ansible。完整 schema 說明：[chezmoi-prefixes.md → Companion file: `.chezmoiexternal.<format>`](../tools/chezmoi-prefixes.md#companion-file-chezmoiexternalformat)。

## Ansible vs Homebrew

**主要工具：Ansible** — 跨平台管理 CLI 工具與系統相依套件 (dependency)。

| 工具 | 角色 | 何時使用 |
|------|------|-------------|
| **Ansible** | CLI 工具、系統套件 | 一律使用（apt / brew formula） |
| **Brewfile** | macOS GUI app (cask)、App Store | 選用 (opt-in) |
| **Linuxbrew** | 不在 apt 中的 Linux 套件 | Linux 上一律安裝 |

Bootstrap 會在 macOS 與 Linux 上同時安裝 Homebrew。Ansible 角色使用 `community.general.homebrew` 處理 macOS formula。Brewfile 另外管理 cask (GUI app) 與 mas (App Store)。在 Linux 上，Ansible 使用 apt；Linuxbrew 用於較新的套件。

關於 Linux 套件來源 (apt / snap / Linuxbrew / GitHub binary) 的深入比較，以及 ansible 角色遵循的策略：[docs/linux-package-sources.md](../linux-package-sources.md)。

## Ansible 用法

Ansible 劇本會在劇本檔案變更時透過 `chezmoi apply` 自動執行。如需手動執行，請使用 `~/.ansible/`：

```bash
cd ~/.ansible

ansible-playbook playbooks/macos.yml                    # Full setup (macOS)
ansible-playbook playbooks/linux.yml                    # Full setup (Linux)
ansible-playbook playbooks/macos.yml --tags "neovim"    # Specific tags only
ansible-playbook playbooks/linux.yml --skip-tags "sudo" # Skip sudo tasks
ansible-playbook playbooks/macos.yml --check            # Dry run
```

修改劇本 / 角色之後，做語法檢查：

```bash
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/base.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
```

或直接使用 `just ansible-syntax-check`。

### 可用的 tag

| Tag | 說明 |
|-----|-------------|
| `base` | git、git-lfs、curl、ripgrep、fd、build tools |
| `homebrew` | macOS Homebrew 更新（安裝由 bootstrap 完成） |
| `zsh` | zsh、oh-my-zsh、外掛 (autosuggestions、syntax-highlighting、completions) |
| `starship` | Starship 跨 shell 提示字元 |
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf、lazygit、tree-sitter-cli、Node.js（透過 `mise`） |
| `devtools` | bat、bats、eza、gh、glab、git-delta、git-graph、tldr、glow、thefuck、zoxide、direnv、yazi、superfile、tmux+tpm、sesh、zellij、btop、htop、taplo、television、pandoc |
| `docker` | Docker / 容器執行環境（macOS 上的 OrbStack、Linux 上的 Docker Engine） |
| `nerdfonts` | 終端機模擬器使用的 Hack Nerd Font |
| `coding_agents` | Claude Code、OpenCode、Cursor CLI、Copilot CLI、Gemini CLI、RTK、SpecStory |
| `bitwarden` | Bitwarden CLI (`bw`) 透過 npm 安裝；桌面 profile 還會安裝 Desktop app，含 zsh 補全 + SSH agent 整合 |
| `security_tools` | `pre-commit`（在所有 OS 上透過 `uv tool install --python 3.13` 安裝——單一真相來源；hook env 故障時執行 `just pre-commit-doctor`）、gitleaks |
| `python_uv_tools` | 透過 `uv` 安裝的 Python CLI 工具 (apprise、mlflow、sqlit-tui、tmuxp 等) |
| `js_cli_tools` | 獨立的 JS / npm CLI 工具（`readnode` 使用的 readability-cli） |
| `llm_tools` | 本機 LLM 工具：Ollama、LiteLLM、llmfit、模型 |
| `rust_cargo_tools` | 透過 cargo 安裝的 Rust CLI 工具 (pueue) |
| `ruby_gem_tools` | 透過 gem 安裝的 Ruby CLI 工具 (try-cli、tmuxinator、toolkami) |
| `input_method` | 繁體中文輸入法：McBopomofo + RIME（macOS 上的 Squirrel、Linux 上的 ibus-rime） |
| `networking_tools` | nmap、arp-scan、mtr、iperf3、doggo、httpie、gping、trippy、bandwhich、speedtest、rustscan |
| `iac_tools` | Azure CLI (`az`)、Terraform、OpenTofu (`tofu`) |
| `gui_apps` | 僅限 Linux 的桌面 app 安裝程式：Alacritty (cargo)、AppImageLauncher、VSCode、Cursor、libfuse2。macOS 對應項目放在 `dot_config/homebrew/Brewfile.darwin.tmpl`。請參閱 [docs/tools/appimage.md](../tools/appimage.md)。 |

完整自訂指南：[ansible_customization.md](ansible_customization.md)。

## Profile

| Profile | OS | 包含的 Tag |
|---------|-----|---------------|
| `macos` | macOS | homebrew、base、zsh、starship、neovim、lazyvim_deps、devtools、docker、nerdfonts、security_tools、rust_cargo_tools、ruby_gem_tools（alacritty 透過 Brewfile cask 安裝） |
| `ubuntu_desktop` | Ubuntu | base、zsh、starship、neovim、lazyvim_deps、devtools、docker、nerdfonts、security_tools、rust_cargo_tools、ruby_gem_tools、gui_apps |
| `ubuntu_server` | Ubuntu | base、zsh、starship、neovim、lazyvim_deps、devtools、docker、security_tools、rust_cargo_tools、ruby_gem_tools |

**Tag 分類：**

- **核心** (全部)：base、zsh、starship、neovim、lazyvim_deps、security_tools
- **桌面** (macos、ubuntu_desktop)：nerdfonts
- **僅 macOS**：homebrew
- **選用**（透過 chezmoi 設定）：coding_agents、bitwarden、python_uv_tools、js_cli_tools、llm_tools、input_method（僅桌面）、networking_tools、iac_tools

`ubuntu_server` 排除 `nerdfonts`（無 GUI 需求）。

## 無 root 模式 (No-root mode) (Linux)

對於沒有 sudo / root 存取權的 Linux 伺服器，於 `chezmoi init` 期間啟用 `noRoot = true`：

```bash
chezmoi init --force  # Answer "y" to "No sudo/root access" prompt
```

這會跳過所有標記 `[sudo]` 的工作（apt 套件、系統層級安裝）。具有使用者層級備援方案的工具會自動安裝到 `~/.local/bin`。

**使用者層級工具**（無需 sudo 自動安裝）：

- **GitHub binary**：neovim、ripgrep、fd、jq、just、bat、bats、eza、delta、yazi、superfile、zellij、btop、gitleaks、lazygit、fzf、sesh、taplo、television
- **tmux-appimage**（僅 x86_64）：解壓的 AppImage → `~/.local/share/tmux-appimage/squashfs-root`，shim 在 `~/.local/bin/tmux`。僅在系統 `tmux` 早於 3.3 時執行。
- **mise**：Node.js、Rust 執行環境管理
- **安裝程式**：zoxide、starship、thefuck、tldr
- **cargo 工具**：pueue
- **uv 工具**：`pre-commit`（鎖定為 `--python 3.13`，請參閱 [docs/tools/pre-commit.md](../tools/pre-commit.md)）、mlflow、sqlit-tui、tmuxp
- **llm 工具**：ollama、litellm、llmfit、模型
- **npm 工具**：Claude Code、OpenCode、Gemini CLI、Bitwarden CLI

**沒有 root 時拿不到的東西**：zsh（需要 `/etc/shells`）、htop、direnv（僅 apt）、Docker、Ollama 服務、系統字型、ruby + gem 工具、build-essential / git / curl / wget / tree（假設已預先安裝）。

**提示**：請系統管理員執行 `sudo apt install git curl wget zsh tmux htop direnv build-essential tree`。

## ARM / Raspberry Pi 支援

Raspberry Pi 5（僅限 64 位元 OS）使用 `ubuntu_server` profile 即可獲得完整工具支援。Raspberry Pi 4 可能執行 32 位元 Raspberry Pi OS（armhf userland）搭配 64 位元 kernel（預設 `arm_64bit=1`），這會導致 `uname -m` 回報 `aarch64`，但 userland 卻是 32 位元。

**處理方式：**

- **Bootstrap** 透過 `dpkg --print-architecture` 偵測 userland 架構；在 armhf 上跳過 Linuxbrew（Homebrew 需要 amd64 或 arm64 userland）。
- **Ansible 劇本** (`linux.yml`) 在 `pre_tasks` 中覆寫 `ansible_architecture` 以匹配真實 userland（例如 `armv7l` 而非 `aarch64`），讓角色下載正確的 binary。
- **armhf 上的工具可用性**：apt 套件可正常運作；GitHub release 下載會跳過沒有 armv7l build 的工具。

**有 armv7l / armhf release 的工具**（在 RPi 4 32 位元上可用）：ripgrep、fd、jq、glow、rclone、direnv、gitleaks、trippy、speedtest、bats。

**在 armv7l 上跳過的工具**（無 32 位元 ARM release）：neovim (GitHub tarball)、lazygit、eza、git-delta、yazi、superfile、zellij、sesh、taplo、television、duckdb、doggo、gping、bandwhich、SpecStory、CodexBar、Claude Code（install.sh 僅提供 arm64/amd64）。

**在 armv7l 上於 mise 中跳過**：bun、ruby；node 釘選為 `node@20`（最後一個有 armv7l tarball 的 LTS）。npm 為基礎的工具透過 `mise exec -- npm` 安裝。tree-sitter-cli 跳過（cargo build 需要 libclang，在 RPi 4 上要花 15+ 分鐘）。

**建議**：使用 64 位元 Raspberry Pi OS 以獲得完整工具相容性。

## Brewfile (GUI app，opt-in)

GUI 應用程式透過 `~/.config/homebrew/` 中的 Homebrew Brewfile 管理。安裝為 **opt-in**（預設停用）：透過 `chezmoi init --force` 啟用，並設定 `installBrewApps = true`。在 macOS 上，AI 桌面應用程式為獨立的 opt-in，透過 `installAiDesktopApps = true` 啟用。

```
~/.config/homebrew/
├── Brewfile          # Shared: taps, CLI formulas, mas
├── Brewfile.darwin   # macOS: casks (GUI apps), mas entries
└── Brewfile.linux    # Linux: linuxbrew-specific (minimal)
```

```bash
chezmoi edit ~/.config/homebrew/Brewfile.darwin       # Edit
brew bundle --file=~/.config/homebrew/Brewfile        # Apply manually
brew bundle check --file=~/.config/homebrew/Brewfile.darwin  # Check
chezmoi apply                                         # Or trigger via run_onchange
```

**分類 (darwin)**：終端機與編輯器 (alacritty、iterm2、warp、cmux、cursor、vscode)、AI 與 coding (claude、chatgpt、opencode-desktop、antigravity、Apple Silicon 上的 codex-app、由 `installAiDesktopApps` + `installLlmTools` 控管的 ollama-app)、系統工具 (aerospace、alt-tab、raycast、jordanbaird-ice)、通訊 (discord、telegram、wechat、tencent-meeting)、瀏覽器 (arc、google-chrome、tor-browser)、生產力 (obsidian、google-drive、grammarly-desktop)、遊戲 (steam、minecraft、battle-net — 若設定了 `WORK_MACHINE` 環境變數則跳過)、金融 (binance、tradingview)、網路 (tailscale、openvpn-connect、clash-verge-rev)、Mac App Store (LINE、Keynote、Numbers、Pages)。

**條件式區塊**（Brewfile 是 chezmoi 樣板 (template)）：

- 遊戲 app：若設定 `WORK_MACHINE` 則跳過。
- 中國 app (baidunetdisk)：僅在 `useChineseMirror` 為 true 時包含。
- mas app：需先登入 App Store.app。
