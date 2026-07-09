# 工具管理器 (tool managers) — 誰安裝什麼

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本 repo 安裝的每個工具的對照表，依照「擁有它的 manager」分類。是
[`upgrades.md`](upgrades.md) 的姊妹文件——那份講升級面，這份講安裝面。

當你想知道：

| 問題 | 章節 |
|---|---|
| 「工具 X 從哪裡來？」 | [§ 工具索引 (A–Z)](#tool-index-az) |
| 「Manager Y 安裝了哪些工具？」 | [§ 各 manager 目錄](#per-manager-catalog) |
| 「我要新增一個工具——該用哪個 manager？」 | [§ 新增工具決策樹](#decision-tree-for-new-tools) |
| 「為什麼 X 由 Z 而不是 W 管理？」 | [§ 多機制工具 + 原因說明](#multi-mechanism-tools--rationale) |
| 「X 怎麼升級？」 | [`upgrades.md`](upgrades.md) |

> 慣例提醒：刻意採用 install-only 設計（見 [`upgrades.md` § 為什麼安裝與升級要分開](upgrades.md#為什麼安裝-install-與升級-upgrade-要分開)）。
> 這裡的每個安裝路徑都使用 `state: present` / `creates:` / `[[ -d … ]]`
> 守衛 (guard)；`chezmoi apply` 不會默默升級任何工具的版本。唯一會刻意
> 推進工具版本的是 `scripts/upgrade_tools.sh`（透過 `just upgrade-*`）。

---

## TL;DR — manager 全景

| Manager | 擁有什麼 | 列在哪 | 升級類別 |
|---|---|---|---|
| **Bootstrap** (`run_once_before_*.sh.tmpl`) | Homebrew 本身、uv、mise、ansible-core、apt 前置條件 | `run_once_before_00_bootstrap.sh.tmpl` | n/a (一次性、冪等) |
| **Homebrew formulae** | macOS 共用 CLI (`mas`) + role 驅動的（在 `base`, `devtools`, `coding_agents` 等之中） | `dot_config/homebrew/Brewfile.tmpl` + 散布在各處的 `community.general.homebrew:` task | `brew` |
| **Homebrew casks** | macOS GUI 應用程式（~25 個；AI 類由 `installAiDesktopApps` 控管） | `Brewfile.darwin.tmpl` | `brew` (`--cask --greedy`) |
| **Ansible roles** | 主要部分——26 個 role，涵蓋 shells、devtools、agents、語言工具鏈、網路、安全 | `dot_ansible/roles/*/tasks/main.yml` | 間接（每個 role 呼叫 brew / apt / mise / uv / npm / cargo / gem / dotnet / curl-installer / github-release 之一） |
| **mise** | Runtime 版本：`node`、`bun`、`rust`、`go`、`dotnet`、`ruby`（oldEL：只有 ruby） | `dot_config/mise/config.toml.tmpl` | `mise` |
| **uv** | Python CLI 工具（`python_uv_tools` ~13 個 + `llm_tools` 1 個 + `litellm`） | `dot_ansible/roles/python_uv_tools/defaults/main.yml`、`dot_ansible/roles/llm_tools/defaults/main.yml`、`coding_agents` 中的 ad-hoc `uv tool install`（specify-cli）+ `security_tools`（pre-commit） | `uv` (`uv tool upgrade --all`) |
| **npm** (全域) | JS CLI（~5 個：copilot-cli、codex、gemini-cli、openchamber、bitwarden、readability-cli）+ `tldr` + `tree-sitter-cli` | `js_cli_tools/defaults/main.yml`、散布的 `community.general.npm:` + `mise exec -- npm install -g` | `npm` (`npm -g update`) |
| **cargo** | Rust crates：`recon`、`pueue`（Linux）、`tree-sitter-cli`（fallback）、`alacritty`（Linux 編譯）、`modelsdev`（Linux fallback） | `rust_cargo_tools/defaults/main.yml`（目前為 `[]`）+ 在 task 中硬寫 | `cargo` (`cargo install-update -a`) |
| **dotnet** (全域工具) | `azure-cost-cli`（binary `azure-cost`） | `dotnet_tools/defaults/main.yml` | `dotnet` |
| **gem** | `try-cli`（binary `try`）、`tmuxinator` | `ruby_gem_tools/defaults/main.yml` | `gem` |
| **curl-installer** (廠商 `install.sh`) | 自管 coding agents + 少數系統工具：claude、opencode、cursor-agent、agy、rtk、ollama、atuin、docker、zoxide、direnv、just、llmfit、starship | `dot_ansible/roles/coding_agents/`、`llm_tools/`、`devtools/`、`starship/`、`atuin/`、`docker/`、bootstrap | `agents`（其中具自我更新 (self-update) 子命令的子集） |
| **GitHub-release 下載** | ~30 個 Linux 使用者層級 fallback：ripgrep/fd/jq/git-lfs/gh/glab/bat/eza/git-delta/diffnav/glow/gum/vhs/freeze/yazi/superfile/btop/zellij/sesh/worktrunk/workmux/tailspin/dasel/yq/jnv/doggo/gping/trippy/bandwhich/rustscan/cloudflared/ngrok/speedtest/gitleaks/lazygit/neovim + macOS specstory/codexbar 的 fallback | 每個 role 的 `_release_fallback` 區塊 | **無**（install-only — 見 [覆蓋落差](#coverage-gaps-install-only-no-automated-upgrade)） |
| **chezmoi externals** | 每週刷新的 git checkout：oh-my-zsh + 插件、oh-my-bash、ble.sh、TPM、fzf（Linux）、toolkami.rb | `.chezmoiexternal.toml.tmpl` | `externals` (`chezmoi apply --refresh-externals`) |
| **apt** / **yum** | 發行版套件（編譯依賴、ffmpeg、audit、fontconfig、libnotify-bin、系統 git/zsh/bash 等） | role 中散布的 `ansible.builtin.apt:` / `ansible.builtin.yum:` | **無**（依賴 repo 流程外的 `apt upgrade`） |
| **flatpak** | Discord（Linux 上的預設頻道） | `gui_apps_linux/tasks/main.yml` | `flatpak` (`flatpak update -y`) |

---

## 安裝順序 {#install-order}

依照時間順序的五個階段。任何後一階段都必須等前一階段存在後才能執行。

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 0 — Bootstrap (run_once_before_*)                                 │
│   curl-installer: Homebrew, uv, mise                                    │
│   apt: build-essential, git, curl (Linux 用 Linuxbrew 的前置條件)        │
│   apt: libffi-dev, libyaml-dev, python3-dev (僅 Linux 非 noRoot)         │
│   uv: ansible-core (固定 Python 3.13)                                   │
│   ansible-galaxy: community.general collection                          │
│   mise: 從 ~/.config/mise/config.toml 安裝 runtimes                      │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 1 — chezmoi apply (部署設定檔)                                     │
│   部署 dot_* 檔案;不直接安裝工具                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 2 — Ansible (run_onchange_after_20_ansible_roles)                 │
│   執行全部 26 個 role;每個分派到其底層 manager                            │
│   (brew / apt / mise / uv / npm / cargo / gem / dotnet / curl / gh-rel) │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 3 — Brew bundle (run_onchange_after_30_brew_bundle)               │
│   針對 ~/.config/homebrew/Brewfile* 執行 `brew bundle --no-upgrade`      │
│   主要是 GUI casks (macOS);installBrewApps=false 時略過                  │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 4 — 各應用 onchange 腳本                                           │
│   completion 重新生成 (run_after_50_generate_completions)                │
│   bat theme cache (run_onchange_after_25_bat_theme)                     │
│   ble.sh 編譯 (run_onchange_after_26_install_blesh)                      │
│   全域 skills 還原 (run_onchange_after_40_install_global_skills)         │
└─────────────────────────────────────────────────────────────────────────┘
```

Bootstrap 是其他一切所依賴的基礎工具的**唯一真實來源 (SSOT)**。如果你
發現自己想在別處加入 `mise` / `uv` / Homebrew,答案幾乎一定是「擴充
bootstrap,然後在 role 中假設它存在」。Linux noRoot 路徑
(`profile=ubuntu_server` 或沒有 sudo 的 RHEL/CentOS) 跳過 apt 前置條件
與 Linuxbrew,改走「每個工具自己的 curl-installer + GitHub releases」
fallback——覆蓋面刻意縮窄(無 GUI、無系統範疇 (system-wide) 安裝)。

---

## 各 manager 目錄 {#per-manager-catalog}

下面每個小節涵蓋一個 manager。格式:

- **擁有什麼 (Owns)** — 哪些工具落入這個 manager 的掌控
- **如何把工具加進去 (How a tool gets there)** — 「我要透過這個 manager 加 X」的標準寫法
- **OS 差異 (Per-OS notes)** — 必要時的分歧
- **升級路徑 (Upgrade path)** — 對應 `upgrades.md` 類別的連結

Ansible roles 小節再依主題切分,因為 26 個 role 擠在同一個表格裡沒法讀。

### 1. Bootstrap 腳本 (pre-chezmoi)

**檔案**:`run_once_before_00_bootstrap.sh.tmpl`、
`run_once_before_02_fix_intel_homebrew.sh.tmpl`、
`run_once_before_50_opencode_migrate.sh.tmpl`

**擁有什麼** — 其他一切都假設存在的四個基礎 manager:

| 工具 | 機制 | OS 差異 |
|---|---|---|
| **Homebrew** | `Homebrew/install` curl 腳本 | macOS 永遠安裝;Linux 只在 `installBrewApps=true` 且非 noRoot 且 arch∈{amd64,arm64} 時安裝。`useChineseMirror=true` 時透過 `HOMEBREW_BREW_GIT_REMOTE` + bottle/API domain 走鏡像（**BFSU** 基準;`brew-mirror` 可切到 USTC/Aliyun/TUNA）。Aliyun 的 `brew.git` 壞掉（會卡住），`HOMEBREW_CORE_GIT_REMOTE` 保持 unset（API 模式）—— 見 [mirrors.md](../tools/mirrors.md) |
| **uv** | `curl -LsSf https://astral.sh/uv/install.sh \| sh` | 全 OS,缺失時 |
| **mise** | `curl https://mise.run \| sh`,加上直接從 `mise.jdx.dev/mise-latest-linux-${arch}[-musl]` 下載的 fallback(glibc < 2.28 時強制 musl) | 全 OS;arch 自動偵測 (x64/arm64/armv7) |
| **ansible-core** | `uv tool install --force --python 3.13 ansible-core` | 全 OS;若現有 ansible 跑在 Python < 3.10 上會強制刷新 |
| **ansible-galaxy: community.general** | `ansible-galaxy collection install --force-with-deps` | 全 OS |
| **mise runtimes** | `mise install --yes`(讀 `~/.config/mise/config.toml`) | 全 OS — 見 [§ mise](#4-mise-執行階段-runtime-版本) |

**Linux 前置條件 (apt)** 用來讓 Linuxbrew + mise Ruby + ansible-cryptography
可編譯:`build-essential`、`procps`、`curl`、`file`、`git`(永遠);
`libffi-dev`、`libyaml-dev`、`python3-dev`(僅非 noRoot)。

**僅 Intel Mac 的旁支腳本**:`run_once_before_02_fix_intel_homebrew.sh.tmpl`
執行 `softwareupdate -i` 抓 Xcode CLT,接著 `brew cleanup` +
`brew link --overwrite git`。

**一次性遷移**:`run_once_before_50_opencode_migrate.sh.tmpl` 把舊版
設定檔搬家(`~/.config/opencode/config.json` → `opencode.json`)。
不是安裝。

**新增到 bootstrap**:只在「新工具必須在 ansible 跑之前就存在」時——
例如 ansible 本身、mise(因為 ansible role 會呼叫 `mise exec`)、uv
(因為某些 role 會呼叫 `uv tool install`)。否則優先用 ansible role。

### 2. Homebrew (formulae + casks)

三個 Brewfile 模板 + ansible role 中散布的
`community.general.homebrew[_cask]` task。切分是**以 macOS 為中心**:
Linux Brewfile 是空的,Linuxbrew 的使用是 role-by-role。

#### 2.1 Brewfiles

| 檔案 | 擁有什麼 |
|---|---|
| `Brewfile.tmpl`(共用) | Taps: `nikitabobko/tap`。Formula(僅 macOS,透過內層 `{{ if eq .chezmoi.os "darwin" }}`): `mas` |
| `Brewfile.darwin.tmpl` | 全部 GUI casks — 見下表 |
| `Brewfile.linux.tmpl` | 空白(只有被註解掉的佔位) |

**macOS casks**(~25 個啟用,由 feature flag 控管):

| Cask | 控管條件 |
|---|---|
| `alacritty`、`warp`、`cmux`、`cursor`、`visual-studio-code` | 永遠 |
| `claude`、`opencode-desktop`、`antigravity` | `installAiDesktopApps` |
| `chatgpt`、`codex-app` | `installAiDesktopApps` + arm64 |
| `codeisland`(tap `wxtsky/tap`) | `installAiDesktopApps` |
| `ollama-app` | `installAiDesktopApps` + `installLlmTools` |
| `nikitabobko/tap/aerospace`、`alt-tab`、`raycast`、`maccy`、`scroll-reverser`、`the-unarchiver`、`applite` | 永遠(系統工具) |
| `discord` | 永遠 |
| `arc` | 永遠 |
| `obsidian`、`google-drive`、`grammarly-desktop`、`super-productivity` | 永遠 |
| `spotify`、`anki` | 永遠 |
| `tailscale-app` | 永遠 |
| `dbeaver-community` | 永遠 |
| `superset` | 僅 arm64 |

還有更多被註解掉的條目(steam、telegram、openvpn-connect 等)——取消註解即可啟用。

#### 2.2 Role 驅動的 brew(formulae + casks)

大多數 CLI formulae 透過 ansible role 而非 Brewfile 安裝。例:

- `base/tasks/main.yml`:`git`、`git-lfs`、`curl`、`wget`、`ripgrep`、`fd`、`jq`、`tree`、`just`
- `devtools/tasks/main.yml`:大量集合——`bat`、`gh`、`glab`、`diffnav`、`git-delta`、`eza`、`tlrc`、`glow`、`gum`、`vhs`、`freeze`、`thefuck`、`zoxide`、`direnv`、`yazi`、`superfile`、`tmux`、`sesh`、`worktrunk`、`workmux`、`zellij`、`btop`、`htop`、`duckdb`、`rclone`、`coreutils`、`taplo`、`television`、`pandoc`、`tailspin`、`lnav`、`grc`、`dasel`、`yq`、`jnv`、`witr`、`figlet`、`toilet`、`lolcat`、`fastfetch`、`shellcheck`、`shfmt`、`bats-core`、`git-graph`
- `coding_agents/tasks/main.yml`:`claude-code`(cask)、`codex`(cask)、`gemini-cli`(formula)、`rtk`(formula)、`specstory`、`codexbar`、`td`、`sidecar`(都有 tap 設定)
- `networking_tools/`:`nmap`、`arp-scan`、`mtr`、`iperf3`、`doggo`、`httpie`、`gping`、`trippy`、`bandwhich`、`rustscan`、`speedtest`(tap `teamookla/speedtest`)、`ngrok`、`cloudflared`
- `media_tools/`:`ffmpeg`、`imagemagick`、`exiftool`、`vips`
- `iac_tools/`:`azure-cli`、`hashicorp/tap/terraform`、`opentofu`
- `llm_tools/`:`llmfit`、`models`、`ollama`
- `security_tools/`:`gitleaks`
- `starship/`、`atuin/`、`neovim/`、`bash/`(gawk)、`zsh/` — 每個都在 macOS 上透過 homebrew formula 安裝主要工具
- `pueue`(來自 `rust_cargo_tools/`):macOS 走 homebrew formula

**OS 分派**在 role 中是通用模式:macOS 分支用
`community.general.homebrew` / `homebrew_cask`;Linux 分支用 apt、
Linuxbrew(存在時)或 GitHub releases。每個 role 都有明確的
`when: ansible_facts["os_family"] == "Darwin"` 守衛。

**Tap 清單**(各 role 加進來的):`nikitabobko/tap`、`wxtsky/tap`
(CodeIsland)、`hashicorp/tap`(terraform)、`teamookla/speedtest`、
`specstoryai/tap`、`steipete/tap`(CodexBar)、`marcus/tap`(td、sidecar)、
`dlvhdr/formulae`、`raine/workmux`。

**透過 homebrew 新增**:只在「macOS 出貨且 Linux 對應品走 apt 或
release tarball」時優先選 brew formula/cask。Linux-first 的工具很少
應該寫進 Brewfile。

#### 2.3 Homebrew prefix 分派輔助

`scripts/upgrade_tools.sh::_uv_install_style`(以及
`python_uv_tools/tasks/main.yml` 中的對應寫法)會檢查 binary 是不是
住在 `brew --prefix` 下,以決定走 `brew upgrade <pkg>` 還是工具的原生
self-update。這避免了「在 brew-uv host 上跑 `uv self update` 默默
no-op」的陷阱——見
[`pitfalls/uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md)。

### 3. Ansible roles

`dot_ansible/roles/` 下的 26 個 role。由
`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`
觸發(任何 role 的 `tasks/main.yml` 或 `defaults/main.yml` 變動時重跑
——SHA256 追蹤)。

**通用模式**:

- `state: present` / `creates:` — install-only,不會默默升級
- 透過 `when: ansible_facts["os_family"] == "Darwin"`(或 `["Debian", "RedHat"]`)做 OS 分支
- 任何 `become: true` task 必加 `tags: [sudo]`(讓 noRoot 模式優雅跳過——見 [`pitfalls/ansible-missing-sudo-tag.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-missing-sudo-tag.md))
- 「工具裝了嗎?」探測用 `failed_when: false` + `register:`
- 發行版套件不存在或太舊時退回使用者層級 fallback 到 `~/.local/bin`(處理 RHEL/CentOS + noRoot + Apple-Silicon-沒有-bottle 的情境)

**Role feature flag**(在 `.chezmoi.toml.tmpl` 透過 prompt 設定):
`installBrewApps`、`installAiDesktopApps`、`installCodingAgents`、
`installLlmTools`、`installPythonUvTools`、`installJsCliTools`、
`installDotnetTools`、`installIacTools`、`installMediaTools`、
`installNetworkingTools`、`installTunnelTools`、`installBitwarden`、
`installInputMethod`、`installAuditd`。Roles 依據對應 flag 自我控管;
bundle 腳本 `scripts/init/dotfiles_init.py` 定義 profile 預設
(`minimal`、規劃中的 `cloud-vm`、預設開發者等)。

#### 3.1 基礎 / 共用 CLI

| Role | 擁有什麼 | OS 機制 |
|---|---|---|
| `base` | `git`、`git-lfs`、`curl`、`wget`、`ripgrep`、`fd`、`jq`、`tree`、`just`、`gcc`/`build-essential`/`make` | macOS:brew formulae · Debian:apt(`fd-find` + `/usr/bin/fd` symlink) · RedHat:yum · `just` 永遠走 `curl https://just.systems/install.sh` · Linux 使用者層級 GitHub-release fallback 到 `~/.local/bin`:ripgrep/fd/jq/git-lfs |
| `homebrew` | (無安裝 — 只做刷新 + 清理,24h 節流) | n/a |
| `atuin` | `atuin` shell history 同步 | macOS:brew formula · Linux:`curl https://setup.atuin.sh \| sh -s -- --non-interactive` → `~/.atuin/bin/` |
| `nerdfonts` | `font-hack-nerd-font` | macOS:brew cask · Linux:從 `nerd-fonts/releases/latest` 下載 `Hack.zip` → `~/.local/share/fonts` + `fc-cache -fv` |

#### 3.2 Shells (`bash`、`zsh`、`starship`)

| Role | 擁有什麼 | OS 機制 |
|---|---|---|
| `bash` | `gawk`(ble.sh 依賴,無條件);homebrew `bash` 5.x + `/etc/shells` + `chsh`(僅 macOS 且 `primary_shell="bash"`) | macOS:brew · Debian:apt · RedHat:yum |
| `zsh` | 系統 `zsh` 套件;若系統 zsh < 5.3,在 RHEL/CentOS 7 上**從原始碼編譯 zsh 5.9** 到 `~/.local`;`primary_shell="zsh"` 時 `chsh`(預設) | macOS:brew · Debian:apt · RedHat:yum + ncurses-devel 原始碼編譯 fallback。oh-my-zsh + 插件以 externals 出貨(§12) |
| `starship` | `starship` prompt | macOS:brew formula · Linux:`curl https://starship.rs/install.sh \| sh -s -- --yes` → sudo `/usr/local/bin` → 使用者 `~/.local/bin` fallback |

`primaryShell` chezmoi prompt 只控管 `chsh` 呼叫——兩個 shell 的 config
不論如何都會部署。詳見 AGENTS.md → "`primaryShell` choice gates `chsh`
only" hard invariant。

#### 3.3 DevTools (巨型 role)

單一 role,~50 個工具——終端機生活 CLI 的雜燴。有一個 backlog 條目
([`backlog/devtools-role-split.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/devtools-role-split.md))
在考慮是否要拆開。

**macOS**(homebrew,taps:`gh-dash` 用 `dlvhdr/formulae`、
`raine/workmux`):`bat`、`bats-core`、`gh`、`glab`、`diffnav`、
`git-delta`、`git-graph`、`eza`、`tlrc`、`glow`、`gum`、`vhs`、
`freeze`、`thefuck`、`zoxide`、`direnv`、`yazi`、`superfile`、`tmux`、
`sesh`、`worktrunk`、`workmux`、`zellij`、`btop`、`htop`、`duckdb`、
`rclone`、`coreutils`、`taplo`、`television`、`pandoc`、`tailspin`、
`lnav`、`grc`、`dasel`、`yq`、`jnv`、`witr`、`figlet`、`toilet`、
`lolcat`、`fastfetch`、`shellcheck`、`shfmt`。

**Linux** — 每個工具分派。模式是**apt/yum(系統)→ GitHub release
tarball 或 installer(使用者)**:

| 工具 | Linux 機制(優先 → fallback) |
|---|---|
| `gh` | GitHub `.deb` → 使用者 tarball |
| `glab` | GitHub `.deb` → 使用者 tarball |
| `bat` | apt + `/usr/bin/bat` symlink → GitHub musl release |
| `bats` | apt → GitHub release `install.sh` |
| `zoxide` | `curl install.sh` |
| `eza` | gierens.de apt repo → 使用者 GitHub musl → brew aarch64 |
| `git-delta` | `.deb`(x86_64)→ brew aarch64 → 使用者 GitHub musl |
| `diffnav` | 使用者 GitHub release |
| `gh-dash` | `gh extension install dlvhdr/gh-dash` |
| `gh-notify` | `gh extension install meiji163/gh-notify` |
| `gh-select` | `gh extension install remcostoeten/gh-select` |
| `git-graph` | 使用者 GitHub release(僅 x86_64) |
| `tldr` | 系統 npm 或 `mise exec -- npm install -g tldr` |
| `glow`、`gum`、`vhs`、`freeze`、`duckdb` | 使用者 GitHub release tarball |
| `rclone` | 官方 installer 或 GitHub release |
| `thefuck` | `uv tool install thefuck`(Python 3.11,distutils workaround) |
| `shellcheck`、`shfmt` | apt 或 release |
| `direnv` | apt 或 installer |
| `yazi`、`superfile`、`btop`、`zellij`、`sesh`、`worktrunk`、`workmux` | Linuxbrew 或 GitHub release |
| `tmux` | apt → 系統版本 < 3.3 時 `nelsonenzo/tmux-appimage` AppImage 到 `~/.local/share/tmux-appimage/`(`display-menu` popup 必須) — 見 AGENTS.md "Tmux popup menu ≥ 3.3 required" |
| `htop`、`pandoc` | apt |
| `taplo`、`television (tv)`、`lnav`、`grc`、`tailspin (tspin)`、`dasel`、`yq`、`jnv`、`witr` | apt + release 混合 |
| `ccze` | 僅 apt(Linux-only 工具,無 macOS 對應品) |

#### 3.4 Coding agents

Role:`dot_ansible/roles/coding_agents/tasks/main.yml`。由
`installCodingAgents` 控管。**最多元異質的 role** — 每個 agent 上游
出貨機制都不同,role 就鏡像了那種多樣性。

| Agent | macOS | Linux | 備註 / 來源行號 |
|---|---|---|---|
| `terminal-notifier` / `libnotify-bin` | brew formula / apt(Debian) | 僅 apt(Debian) | 通知輔助,9–29 行 |
| **Claude Code** | brew cask `claude-code` | `curl https://claude.ai/install.sh \| bash` → `~/.claude/local/bin/claude` | 33–71 行;非 amd64/arm64 架構跳過 |
| **OpenCode** | `curl https://opencode.ai/install \| bash -s -- --no-modify-path` → `~/.opencode/bin/opencode` | 同 | 73–107 行。跨平台統一安裝;`--no-modify-path` 阻止 installer 改寫 chezmoi 管理的 shell rc。容器映像 (container image) 變體見 [`pitfalls/opencode-docker-opentui-glibc-loader-missing.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/opencode-docker-opentui-glibc-loader-missing.md) |
| **Cursor CLI**(`cursor-agent`) | `curl https://cursor.com/install \| bash` | 同 | 112–124 行;brew cask 因簽章 (code-signing) 問題棄用 |
| **GitHub Copilot CLI** | npm `@githubnext/github-copilot-cli`(全域) | `mise exec -- npm install -g` | 134–168 行 |
| **OpenAI Codex CLI** | brew cask `codex` | `mise exec -- npm install -g @openai/codex` | 172–236 行 |
| **Gemini CLI** | brew formula `gemini-cli` → npm `@google/gemini-cli` fallback | `mise exec -- npm install -g` | 240–300 行 |
| **Antigravity CLI**(`agy` + `agyc` symlink) | `curl https://antigravity.google/cli/install.sh`,中途用 `sed` 改寫成 `--skip-path --skip-aliases` | 同 | 317–355 行。兩個雷區:(a) 與 Antigravity IDE 同名 — 無衝突的 `agyc` symlink 是 AICAP 堆疊的鑰匙;(b) installer 預設會改 shell profiles — 已 patch 掉。兩者皆有 in-source 文件 |
| **RTK** | brew formula `rtk` | `curl https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh \| sh` → `~/.local/bin/rtk` | 359–413 行 |
| **SpecStory** | brew tap `specstoryai/tap` + formula → GitHub release zip fallback | GitHub release tarball | 417–595 行 |
| **CodexBar** | brew tap `steipete/tap` + cask(僅 arm64) | Linuxbrew → GitHub release `steipete/CodexBar` | 599–764 行 |
| **td** | brew tap `marcus/tap` + formula | Linuxbrew → GitHub release `marcus/td` | 768–975 行。包含「現有 td 是否與 Sidecar 相容?」版本檢查;不相容則移除衝突的 formula |
| **sidecar** | brew tap `marcus/tap` + formula | Linuxbrew → GitHub release `marcus/sidecar` | 979–1149 行 |
| **Specify CLI** | `uv tool install specify-cli --from git+https://github.com/github/spec-kit.git` | 同 | 1153–1184 行。目前唯一在 role 中直接用 `uv tool install` 而非透過 `python_uv_tools` defaults 的工具 |
| **OpenChamber** | npm `@openchamber/web` | `mise exec -- npm install -g` | 1188–1222 行 |
| **claude-hud** 插件 | 執行 `files/claude_hud_sync.py --only-if-missing` | 同 | 1239–1247 行;install-only,顯式的 `just upgrade-plugins` 才會刷新 |

**AICAP agent 堆疊的 SSOT**:`dot_config/shell/04_ai_agents.sh` 定義
自動偵測順序 + `AICAP_*_MODEL` 預設值。四個 Python 消費者 regex parse
同一份檔案(見 AGENTS.md cross-file rule)。在此新增 agent 時要同時:
在本 role 安裝 + 加到 SSOT + 四個 Python `AGENT_CONFIG` dict。

#### 3.5 語言工具鏈 (`python_uv_tools`, `ruby_gem_tools`, `rust_cargo_tools`, `dotnet_tools`, `js_cli_tools`)

語言專用套件管理器的 wrapper。全部都讀取 `defaults/main.yml` 清單,
所以 role 的 `tasks/main.yml` 是個迴圈。工具清單見
[§ uv](#5-uv-python-cli-工具)、[§ npm](#6-npm-全域-node-cli)、
[§ cargo](#7-cargo-rust-crates)、[§ dotnet](#8-dotnet-全域-net-工具)、
[§ gem](#9-gem-ruby-gems)。

| Role | 底層 manager | 工具(數量) | Gate |
|---|---|---|---|
| `python_uv_tools` | `uv tool install` | 13 | `installPythonUvTools` |
| `llm_tools` | `uv tool install` + brew + cargo + curl-installer | 4(litellm、llmfit、models、ollama) | `installLlmTools` |
| `js_cli_tools` | `mise exec -- npm install -g` / 系統 npm | 1(`readability-cli`) | `installJsCliTools` |
| `rust_cargo_tools` | `cargo install`(在 `mise install rust@latest` 之後) | defaults 中 `[]` + 2 個 hard-code(`recon`、`pueue`) | (無 gate;rust runtime 永遠透過 mise 安裝) |
| `ruby_gem_tools` | `gem install`(在 `mise install ruby@3` 之後) | 2(`try-cli`、`tmuxinator`) | (無 gate;在 noRoot Linux 上由 `mise install ruby` 跳過來 gate) |
| `dotnet_tools` | `dotnet tool install --global`(在 `mise use -g dotnet@latest` 之後) | 1(`azure-cost-cli`) | `installDotnetTools` |

**關鍵 invariant**(`with_executables_from:` 條目**必須**同時宣告
`extra_binaries:`):見 AGENTS.md "Install vs upgrade is split on
purpose" hard invariant 的稽核 one-liner 與相關 pitfall。

#### 3.6 編輯器 + 插件 (`neovim`, `lazyvim_deps`, `nerdfonts`)

| Role | 擁有什麼 | OS 機制 |
|---|---|---|
| `neovim` | `neovim` ≥ 0.11.2(macOS 上 `state: latest`) | macOS:brew formula · Linux:apt → 太舊則 GitHub release tarball(`/opt/nvim` + `/usr/local/bin/nvim` symlink) → 使用者層級 tarball 到 `~/.local`;**oldEL** 抓 `neovim/neovim-releases`(glibc 2.17 重建 repo)。不用 snap(2026-06 移除——見 [linux-package-sources.zh-TW.md → 這個 repo 的 snap 使用現況](../linux-package-sources.zh-TW.md#這個-repo-的-snap-使用現況))。見 [`pitfalls/centos7-neovim-apt-register-defined.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/centos7-neovim-apt-register-defined.md) |
| `lazyvim_deps` | `fzf`、`lazygit`、`tree-sitter`、`node` | macOS:brew · Linux:mise(一般情境 `node@lts`;armv7l 上 `node@20` + `rust@latest`);fzf 由 chezmoi external clone 編譯(Linux);lazygit PPA → GitHub release;tree-sitter-cli 透過 `mise exec -- npm install -g tree-sitter-cli`(timeout 180)→ cargo fallback 並先裝 `libclang-dev`/`clang-devel` |
| `nerdfonts` | (見 [§ 3.1 基礎/共用](#31-基礎--共用-cli)) | — |

#### 3.7 網路 + IaC + LLM + 媒體 (`networking_tools`, `iac_tools`, `llm_tools`, `media_tools`)

| Role | 擁有什麼 | OS 機制 |
|---|---|---|
| `networking_tools` | `nmap`、`arp-scan`、`mtr`、`iperf3`、`doggo`、`httpie`、`gping`、`trippy`、`bandwhich`、`rustscan`、`speedtest`(Ookla) | macOS:brew(speedtest 用 tap `teamookla/speedtest`) · Linux:apt + GitHub-release fallback(musl)到 `~/.local/bin`,給沒有 apt 套件的工具 |
| `networking_tools`(tunnel 子集,`installTunnelTools` + tag `tunnel_tools` 控管) | `ngrok`、`cloudflared` | macOS:brew cask `ngrok` + brew formula `cloudflared` · Debian:ngrok apt repo + cloudflared `.deb` · RedHat:cloudflared `.rpm` · noRoot:使用者層級 tarball fallback |
| `iac_tools`(`installIacTools` 控管;每工具皆有 toggle) | `azure-cli`、`terraform`、`opentofu` | macOS:brew(terraform 用 hashicorp/tap) · Linux:廠商 apt repo(Microsoft / HashiCorp / Cloudsmith)→ 使用者層級 zip / `uv tool install azure-cli` fallback |
| `llm_tools`(`installLlmTools` 控管) | `litellm[proxy]`(透過 uv)、`llmfit`、`models`、`ollama` | 混合 — macOS 用 brew formula / Linux 用 curl-installer。Ollama:永遠 brew formula(CLI) + `installBrewApps` 時 Brewfile 的 cask `ollama-app`;Linux 用 `curl https://ollama.com/install.sh`(sudo,noRoot 跳過) |
| `media_tools`(`installMediaTools` 控管) | `ffmpeg`、`imagemagick`、`exiftool`、`vips` | macOS:brew · Debian:apt(`libimage-exiftool-perl`、`libvips-tools`) |

#### 3.8 系統 / GUI / 安全 (`docker`, `gui_apps_linux`, `auditd`, `security_tools`, `bitwarden`, `input_method`, `atuin`, `homebrew`)

| Role | 擁有什麼 | OS 機制 |
|---|---|---|
| `docker` | OrbStack(macOS)、Docker rootless(Linux) | macOS:brew cask `orbstack`(`/Applications/Docker.app` 存在則跳過) · Debian/Ubuntu:`apt` 前置條件(`uidmap`、`dbus-user-session`、`fuse-overlayfs`、`slirp4netns`、`iptables`)→ `curl https://get.docker.com \| sh` → `docker-ce-rootless-extras` → `dockerd-rootless-setuptool.sh install` 使用者 systemd unit |
| `gui_apps_linux`(Linux Debian + `ubuntu_desktop` profile) | Alacritty、libfuse2、AppImageLauncher、VSCode、Cursor、Discord、Zen Browser、CopyQ、playerctl/wmctrl/xdotool | Alacritty:cargo 編譯(apt 依賴 `cmake`、`pkg-config`、字型/X 函式庫) · AppImageLauncher:PPA → GitHub `.deb` → Lite AppImage 到 `~/Applications/` · VSCode:Microsoft apt repo · Cursor:`.deb` 來自 `cursor.com/api/download` · Discord:flatpak(Flathub user-scope,預設)或 `.deb`,由 `discordChannel` 選擇 · Zen Browser:AppImage 到 `~/Applications/zen.AppImage` |
| `auditd`(Linux,`installAuditd` 控管) | `auditd` + `audispd-plugins`(Debian)/ `audit`(RedHat);rule 檔 `00-baseline.rules`、`05-privileged.rules`、選用 `10-execve.rules`、`99-finalize.rules` | apt / yum |
| `security_tools` | `pre-commit`、`gitleaks` | macOS:brew(`gitleaks`)+ uv(`pre-commit`) · Linux:gitleaks 來自 GitHub release(系統 → `/usr/local/bin`;使用者 fallback → `~/.local/bin`)+ uv pre-commit。**Go 已不在此** — 移到 mise(`go = "latest"`,gate 於 `installExtraRuntimes`)。 |
| `bitwarden`(`installBitwarden` 控管) | `@bitwarden/cli` + Bitwarden Desktop(`bitwarden_install_desktop=true` 時) | CLI:`mise exec -- npm install -g @bitwarden/cli`(優先)/ 系統 npm fallback · Desktop:macOS brew cask · Linux:snap → `.deb` fallback |
| `input_method`(`installInputMethod` 控管) | `mcbopomofo`、`squirrel`(macOS)· `ibus-rime`(Debian) | macOS:brew cask · Linux:apt |
| `atuin` | (見 [§ 3.1 基礎/共用](#31-基礎--共用-cli)) | — |
| `homebrew` | (見 [§ 2 Homebrew](#2-homebrew-formulae--casks)) | — |

### 4. mise (執行階段 (runtime) 版本)

**設定檔**:`dot_config/mise/config.toml.tmpl`

`[settings]`:`ruby.compile = false`。

**現代主機**(預設):

| Runtime | 版本 | gate 條件 |
|---|---|---|
| `node` | `lts` | 一律安裝 |
| `bun` | `1` | `installExtraRuntimes` |
| `rust` | `stable` | `installExtraRuntimes` |
| `go` | `latest` | `installExtraRuntimes` |
| `dotnet` | `10` | `installDotnetTools` |
| `ruby` | `3` | `installExtraRuntimes`(且非 `noRoot`) |

**版本釘選理由**:`node=lts` / `rust=stable` / `go=latest` 使用浮動
channel,因為它們各自承諾向後相容(Go 的
[go1compat](https://go.dev/doc/go1compat) 讓 `latest` 如同 rust 的
`stable` 一樣安全)。`bun=1` 與 `dotnet=10` 改為釘住**主版號** —
兩者都不保證跨主版號不破壞(bun 在 minor 就會有行為變更;.NET 主版號
會 bump TFM / SDK 行為),且 `dotnet=10` 也是目前的 LTS(8/9 在 2026
年中已到/接近 EOL)。下一個 LTS(12)推出時再刻意 bump `dotnet`。
`ruby=3` 追蹤 3.x 線。

`go` 取代了原本 `security_tools` role 中僅限 macOS 的 brew 安裝,因此
Linux 主機現在也有受管的 Go(先前是缺口)。

Ruby 在 noRoot 模式下**會跳過**(`profile=ubuntu_server` 無 sudo),
因為它需要 `libffi-dev` / `libyaml-dev` 才能編譯,而那需要 apt。

**oldEL**(CentOS/RHEL 7、glibc 2.17):只有 `ruby = "3"` — 其他
runtime 的 glibc/libstdc++ 需求對 EL7 來說太新。

**升級**:`just upgrade-mise` → `mise self-update --yes` + `mise upgrade`
(遵守設定檔中的版本約束;`lts`/`latest` 會往前移,釘住的版本不會)。

**新增 runtime**:直接編輯 `dot_config/mise/config.toml.tmpl`。跨機器
的 runtime 版本控管在 [backlog](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/mise-runtime-gating.md)。

**為什麼選 mise(而不是 nvm/rbenv/pyenv/asdf/n)**:統一、語言無關、
尊重 `.tool-versions`、不與 shell 啟動順序打架。Python 刻意**不**用 mise
管理 — 那是 uv 的地盤(更快 + 不需要從原始碼編譯 CPython,而 noRoot
Linux 路徑無法編譯)。
[backlog](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/mise-runtime-gating.md)
追蹤更細粒度的跨主機控管。

### 5. uv (Python CLI 工具)

**設定檔**:`dot_ansible/roles/python_uv_tools/defaults/main.yml`
(+ `llm_tools/defaults/main.yml` 中的 `litellm`)。Role 層級分派:
`dot_ansible/roles/python_uv_tools/tasks/main.yml`。

檢查 `uv` 是否低於 `min_uv_version`(`0.8.5`),分派升級到對應通道——
Homebrew 安裝走 `brew upgrade uv`、curl-installer 安裝走
`uv self update`。`scripts/upgrade_tools.sh::cat_uv()` 中有鏡像邏輯。
詳見 [`docs/this_repo/uv-bootstrap.md`](uv-bootstrap.md) 與
[`pitfalls/uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md)。

**工具清單**(`python_uv_tools/defaults/main.yml`):

| 工具 | `--with` / `--with-executables-from` | `needs_modern_gcc` |
|---|---|---|
| `thefuck` | (python 3.11;distutils workaround) | — |
| `apprise` | — | — |
| `sqlit-tui[ssh]` | `psycopg2-binary`, `pymysql`, `mssql-python`, `pyodbc`, `duckdb` | ✓(gcc ≥ 9) |
| `python-dotenv[cli]`(`dotenv`) | — | — |
| `git-filter-repo` | — | — |
| `mlflow` | — | ✓ |
| `tmuxp` | — | — |
| `visidata`(`vd`) | `pandas`, `pyarrow` | ✓ |
| `copyparty` | — | — |
| `trafilatura` | — | — |
| `marimo[recommended,mcp]` | `httpx[socks]` | ✓ |
| `jupyterlab`(`jupyter-lab`) | `marimo[sandbox]`, `marimo-jupyter-extension`, `ipykernel`, `ipywidgets`;`with_executables_from: notebook, jupyter-core`;`extra_binaries: jupyter, jupyter-notebook` | ✓ |
| `xonsh` | `xontrib-jedi`, `xontrib-zoxide`, `xontrib-pipeliner`, `xontrib-fzf-widgets` | — |
| `yt-dlp` | — | — |

來自 `llm_tools/defaults/main.yml`:

| 工具 | 釘住 |
|---|---|
| `litellm[proxy]`(`litellm`) | `--python 3.13`, `--with httpx[socks]` |

defaults YAML 之外的 ad-hoc `uv tool install`:

- `coding_agents/tasks/main.yml:1153-1184` — `specify-cli`(從 `git+...`)
- `security_tools/tasks/main.yml` — `pre-commit`(`--python 3.13`,
  避開 Homebrew Python 3.14 pyexpat ABI 不相容)
- `iac_tools/tasks/main.yml` — `azure-cli` 使用者 fallback(Linux noRoot)

**升級**:`just upgrade-uv` → uv self-update(已分派)+ `uv tool upgrade --all`。

**新增 uv 工具**:在 `python_uv_tools/defaults/main.yml` 附加。如果套件
會在入口點之外寫入伴隨 binary,**必須**同時宣告
`with_executables_from:` AND `extra_binaries:`——否則在主要 binary 已
存在的主機上 install guard 會短路而 shim 永遠不會寫入
([`pitfalls/uv-tool-install-creates-guard-misses-executables-from.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-tool-install-creates-guard-misses-executables-from.md))。
如果範圍內有 gcc < 9 的主機,設 `needs_modern_gcc: true`。

### 6. npm (全域 Node CLI)

**設定檔**:`dot_ansible/roles/js_cli_tools/defaults/main.yml` 是 JS
工具專屬清單。其他散布在各 role 的全域 npm 安裝在
(`coding_agents`、`bitwarden`、`lazyvim_deps`、`devtools`)。

**安裝分派**(跨 role 的通用模式):

```yaml
# Linux 上:
mise exec -- npm install -g <package>
# 如果 mise 沒註冊 node 則退回系統 npm
# macOS 上:
community.general.npm: { name: <package>, global: true }
```

Linux 顯式用 `mise exec -- npm` 避開 Ubuntu apt 的 npm(太舊;系統
Node 12 連現代套件的 `engine` 檢查都過不了,而且 `/usr/local/lib/node_modules`
是 root-owned,讓非 root 使用者的 `--global` 安裝壞掉)。見
[`pitfalls/ansible-js-cli-tools-old-system-node.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-js-cli-tools-old-system-node.md)。

**清單**:

| 套件 | Binary | Role / 行號 |
|---|---|---|
| `readability-cli` | `readable` | `js_cli_tools/defaults/main.yml` |
| `@bitwarden/cli` | `bw` | `bitwarden/tasks/main.yml` |
| `@githubnext/github-copilot-cli` | `github-copilot-cli` | `coding_agents/tasks/main.yml:134-168` |
| `@openai/codex` | `codex`(僅 Linux — macOS 走 brew cask) | `coding_agents/tasks/main.yml:172-236` |
| `@google/gemini-cli` | `gemini`(Linux 永遠;macOS 在 brew formula 失敗時 fallback) | `coding_agents/tasks/main.yml:240-300` |
| `@openchamber/web` | `openchamber` | `coding_agents/tasks/main.yml:1188-1222` |
| `tldr` | `tldr`(僅 Linux — macOS 走 brew 的 `tlrc`) | `devtools/tasks/main.yml` |
| `tree-sitter-cli` | `tree-sitter` | `lazyvim_deps/tasks/main.yml`(優先於 cargo fallback) |

**升級**:`just upgrade-npm` → `npm -g update`,有 `mise exec --` fallback。

**新增 npm 工具**:在 `js_cli_tools/defaults/main.yml` 附加(給一般工具);
若是 agent CLI,改在 `coding_agents/tasks/main.yml` 新增安裝 task,
按現有分派模式(macOS 用系統 npm,Linux 用 `mise exec -- npm install -g`)。

### 7. cargo (Rust crates)

**設定檔**:`dot_ansible/roles/rust_cargo_tools/defaults/main.yml`
(目前 `cargo_tools: []` — 沒有泛用條目)。

**Rust 安裝**:`mise install rust@latest`(優先),在 noRoot/oldEL 主機
上有兩層 fallback:直接 `rustup-init`、設定的 mirror manifest 過期
時退回 `https://static.rust-lang.org`。

**清單**(`tasks/main.yml` 中 hard-coded):

| Crate | 機制 | 備註 |
|---|---|---|
| `recon` | `cargo install --git https://github.com/gavraz/recon --locked` | git source(尚未發到 crates.io) |
| `pueue` | macOS brew formula;Linux `cargo install pueue --locked` | + `pueued.service` systemd user unit;版本檢查 `pueue_min_version=4.0.0`(僅警示) |
| `tree-sitter-cli` | `cargo install tree-sitter-cli`(只當 fallback) | 優先路徑是 `mise exec -- npm install -g tree-sitter-cli`;cargo 路徑會先裝 `libclang-dev`/`clang-devel` |
| `alacritty` | cargo 編譯(`gui_apps_linux`) | 需要 apt 編譯依賴(`cmake`、`pkg-config`、`libfontconfig1-dev`、`libxcb-xfixes0-dev`、`libxkbcommon-dev`) |
| `modelsdev` | cargo fallback(`llm_tools`) | 只在 Linuxbrew 不存在 + brew formula `models` 也不可用時 |
| `cargo-update` | `cargo install cargo-update`(給升級用的 bootstrap) | 第一次跑 `upgrade_tools.sh::cat_cargo` 時安裝,之後 `cargo install-update -a` 就會用它 |

**升級**:`just upgrade-cargo` → `cargo install-update -a`(涵蓋所有
透過 cargo 安裝的東西,包括 Linux 上的 pueue)。

**新增 cargo 工具**:優先 `cargo_tools: [<name>]` 寫到 defaults YAML
(由 `cargo install-update -a` 涵蓋);只在安裝需要額外編譯依賴或非
crates.io 來源時才 hard-code 到 `tasks/main.yml`(見 `recon`、`pueue`)。

### 8. dotnet (全域 .NET 工具)

**設定檔**:`dot_ansible/roles/dotnet_tools/defaults/main.yml`

**.NET SDK** 透過 `mise use -g dotnet@<version>`(預設 `latest`)。
SDK 裝好後,role 對每個條目跑 `dotnet tool install --global` 迴圈 —
binary 放到 `~/.dotnet/tools/`(已經由
`dot_config/shell/00_exports.sh.tmpl` 加到 PATH)。

**清單**:

| 套件 | Binary |
|---|---|
| `azure-cost-cli` | `azure-cost` |

**升級**:`just upgrade-dotnet` → 對每個工具重跑 `dotnet tool update --global`。

**新增 dotnet 工具**:在 `dotnet_tools/defaults/main.yml` 附加,提供
`name`(NuGet package id)與 `binary`(實際命令名)。

### 9. gem (Ruby gems)

**設定檔**:`dot_ansible/roles/ruby_gem_tools/defaults/main.yml`

**Ruby 安裝**:`mise install ruby@3`(noRoot Linux 跳過)。先裝編譯
依賴:`libffi-dev`、`libyaml-dev`(Debian)/ `libffi-devel`、
`libyaml-devel`(RedHat)。

**清單**:

| Gem | Binary |
|---|---|
| `try-cli` | `try` |
| `tmuxinator` | `tmuxinator` |

加上 `toolkami.rb` 由 chezmoi external 抓取(見 § 12 — 獨立執行,
不透過 `gem install`)。

**升級**:`just upgrade-gem` → `gem update`。

**新增 gem**:在 `ruby_gem_tools/defaults/main.yml` 附加(noRoot Linux
上會自動跳過,因為那邊 ruby 沒裝)。

### 10. curl-installer (自管 CLI)

透過廠商 `install.sh` 而非套件管理器出貨的工具。主要是 AI coding
agents(每個廠商自己維護 installer + self-update 子命令)。所有 landing
路徑都是使用者可寫,讓 in-binary self-update 不用 sudo 就能用。

**清單**:

| 工具 | 安裝 URL | 落地處 | 來源 role |
|---|---|---|---|
| Homebrew | `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` | `/usr/local/bin/brew`(macOS)/ `/home/linuxbrew/.linuxbrew/`(Linux) | bootstrap |
| uv | `https://astral.sh/uv/install.sh` | `~/.local/bin/uv`(或 `~/.cargo/bin/uv`) | bootstrap |
| mise | `https://mise.run` | `~/.local/bin/mise` | bootstrap |
| just | `https://just.systems/install.sh` | `/usr/local/bin/just` 或 `~/.local/bin/just` | `base` |
| starship | `https://starship.rs/install.sh` | `/usr/local/bin/starship` 或 `~/.local/bin/starship` | `starship` |
| atuin | `https://setup.atuin.sh` | `~/.atuin/bin/atuin` | `atuin` |
| docker | `https://get.docker.com` | 系統 docker(rootless 變體) | `docker`(Linux) |
| zoxide | (廠商 installer) | `~/.local/bin/zoxide` | `devtools`(Linux fallback) |
| direnv | (廠商 installer) | `~/.local/bin/direnv` | `devtools`(Linux fallback) |
| **Claude Code** | `https://claude.ai/install.sh` | `~/.claude/local/bin/claude` | `coding_agents`(Linux) |
| **OpenCode** | `https://opencode.ai/install`(+ `--no-modify-path`) | `~/.opencode/bin/opencode` | `coding_agents`(macOS + Linux) |
| **Cursor CLI** | `https://cursor.com/install` | `~/.local/bin/cursor-agent` | `coding_agents` |
| **Antigravity CLI** | `https://antigravity.google/cli/install.sh`(改寫成 `--skip-path --skip-aliases`) | `~/.local/bin/agy` + `agyc` symlink | `coding_agents` |
| **RTK** | `https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh` | `~/.local/bin/rtk` | `coding_agents`(Linux) |
| **llmfit** | `https://llmfit.axjns.dev/install.sh` | `~/.local/bin/llmfit`(或系統) | `llm_tools`(Linux) |
| **Ollama** | `https://ollama.com/install.sh` | 系統路徑(Linux,sudo) | `llm_tools`(Linux) |
| Ookla speedtest | `https://install.speedtest.net/app/cli/install.<distro>.sh` | 系統 | `networking_tools`(Linux) |

**為什麼選 curl-installer 而非套件管理器**:

- 快速迭代的 release — 廠商控制節奏(Claude、OpenCode、Cursor、
  Antigravity 每天/每週推送)
- 存在 self-update 子命令 + installer 是標準重裝路徑 →
  `scripts/upgrade_tools.sh` 的 `cat_agents` 兩種都可呼叫
- 避開「brew formula 落後 3 週」的問題(見 OpenCode 從 `anomalyco/tap`
  搬到官方 installer 的 commit 歷史)
- 不用維護 tap/PPA/repo

**新增 curl-installer 工具**:

1. 選一個 role(agent 就放 `coding_agents`)
2. 用標準模式:`which` 檢查 → binary 路徑上的 `creates:` 守衛 →
   `curl ... | bash [-s -- --no-modify-path]` shell task
3. 如果 installer 會改 shell rc 檔,加 `--no-modify-path` flag(或對等
   ——見 OpenCode 與 Antigravity 區塊)。chezmoi 管理的 PATH 是 SSOT
4. 如果工具有 self-update 子命令(或 installer-as-upgrader 路徑),
   更新 `scripts/upgrade_tools.sh::cat_agents`
5. 如果 binary 落在 `~/.local/bin` 以外(例如 `~/.opencode/bin/opencode`),
   到 `dot_config/shell/00_exports.sh.tmpl` 加一個存在性守衛的 PATH 前置

### 11. GitHub-release 下載 (使用者層級 fallback)

當 apt/yum 不能滿足版本需求(例如 Apple Silicon brew bottle 缺失、
RHEL/CentOS 套件太舊、無 sudo 的 noRoot 主機),role 退回下載最新
GitHub release tarball 並解壓到 `~/.local/bin`(使用者可寫,已在 PATH)。

**標準寫法**:

```yaml
- name: Get latest <tool> release
  ansible.builtin.uri:
    url: https://api.github.com/repos/<owner>/<repo>/releases/latest
    return_content: true
  register: <tool>_release

- name: Compute <tool> arch
  ansible.builtin.set_fact:
    <tool>_arch: "{{ 'amd64' if target_architecture in ['x86_64', 'amd64'] else 'arm64' if ... else 'unsupported' }}"

- name: Download / extract / copy into ~/.local/bin
  block:
    - get_url: { url: "https://github.com/.../{{ tag }}/{{ asset }}", dest: /tmp/..., retries: 3, delay: 5, timeout: 120 }
    - unarchive: { src: ..., dest: /tmp/..., remote_src: true }
    - find:      { paths: /tmp/..., patterns: <binary>, file_type: file }
    - copy:      { src: ..., dest: "{{ ansible_facts['env']['HOME'] }}/.local/bin/<binary>", mode: '0755' }
  rescue:
    - debug: "<tool> installation failed (likely network timeout) - skipping"
```

**使用此模式的工具**(粗略清單 — 見各 role 的 `tasks/main.yml`):

- `base`:`ripgrep`、`fd`、`jq`、`git-lfs`
- `devtools`:`gh`、`glab`、`bat`、`bats`、`eza`、`git-delta`、
  `diffnav`、`git-graph`、`glow`、`gum`、`vhs`、`freeze`、`duckdb`、
  `yazi`、`superfile`、`btop`、`zellij`、`sesh`、`worktrunk`、
  `workmux`、`taplo`、`tv`(television)、`lnav`、`tailspin`、`dasel`、
  `yq`、`jnv`、`witr`
- `networking_tools`:`doggo`、`gping`、`trippy`、`bandwhich`、
  `rustscan`、`cloudflared`
- `neovim`:nvim tarball
- `lazyvim_deps`:`lazygit` fallback
- `coding_agents`:`specstory`、`codexbar`、`td`、`sidecar`、`agy`
  (都同時有 brew formula / cask 當主要路徑)
- `security_tools`:`gitleaks`
- `iac_tools`:`terraform`、`opentofu` 使用者 fallback(來自
  `releases.hashicorp.com` / GitHub 的 zip)
- `gui_apps_linux`:`AppImageLauncher Lite`、Zen Browser AppImage
- `bitwarden`:Desktop `.deb` fallback(Linux)

**⚠️ 覆蓋落差**:GitHub-release 下載用 binary 路徑上的 `creates:` 守衛,
所以一旦安裝就**永遠不會被 `chezmoi apply` 刷新**——而
`scripts/upgrade_tools.sh` 沒有對應類別。唯一刷新方式:`rm` binary
後重 apply。見下面的 [§ 覆蓋落差](#coverage-gaps-install-only-no-automated-upgrade)。

**新增 GitHub-release 工具**:從例如 `devtools/tasks/main.yml` 複製
標準區塊(找一個架構矩陣類似的現有工具),替換 owner/repo/asset-name。
永遠包在 `block:` / `rescue:` 裡(廠商端會出包),下載用
`retries: 3, delay: 5, timeout: 120`。

### 12. chezmoi externals (週期刷新 git/檔案抓取)

**設定檔**:`.chezmoiexternal.toml.tmpl`

`chezmoi apply` 依排程抓取這些。全部設 `refreshPeriod = "168h"`
(每週),`--depth 1` 淺 clone,`--ff-only` 拉取。

| 路徑 | 類型 | 來源 | 控管條件 |
|---|---|---|---|
| `.oh-my-zsh` | git-repo | `ohmyzsh/ohmyzsh.git` | 永遠 |
| `.oh-my-zsh/custom/plugins/zsh-autosuggestions` | git-repo | `zsh-users/zsh-autosuggestions.git` | 永遠 |
| `.oh-my-zsh/custom/plugins/zsh-syntax-highlighting` | git-repo | `zsh-users/zsh-syntax-highlighting.git` | 永遠 |
| `.oh-my-zsh/custom/plugins/zsh-completions` | git-repo | `zsh-users/zsh-completions.git` | 永遠 |
| `.oh-my-zsh/custom/plugins/zsh-vi-mode` | git-repo | `jeffreytse/zsh-vi-mode.git` | `enableVimMode` |
| `.oh-my-bash` | git-repo | `ohmybash/oh-my-bash.git` | 永遠 |
| `.local/src/blesh` | git-repo(`--recurse-submodules`) | `akinomyoga/ble.sh.git` | 永遠;由 `run_onchange_after_26_install_blesh.sh.tmpl` 編譯 → `~/.local/share/blesh/ble.sh` |
| `.tmux/plugins/tpm` | git-repo | `tmux-plugins/tpm.git` | 永遠 |
| `.fzf` | git-repo | `junegunn/fzf.git` | 僅 Linux(ansible 跑 `~/.fzf/install --bin`) |
| `.local/share/toolkami/toolkami.rb` | file(executable) | `https://raw.githubusercontent.com/aperoc/toolkami/refs/heads/main/toolkami.rb` | 永遠 |

**為什麼選 externals(而不是在 role 裡 git clone)**:

- 刷新節奏內建(chezmoi 自己照排程做 `git pull`;ansible role 沒有
  「每 N 小時 re-pull」的基本元素)
- 一個地方就能看到「這台機器上有哪些第三方原始碼」
- `chezmoi update --refresh-externals` 是明確的強制刷新

**升級**:`just upgrade-externals` → `chezmoi apply --refresh-externals`。

**新增 external**:在 `.chezmoiexternal.toml.tmpl` 前置條目。如果 clone
後需要編譯步驟(像 ble.sh),掛一個
`run_onchange_after_NN_*.sh.tmpl` 腳本在 external 的 commit 變動時
重跑。

**過往 pitfall**:

- ble.sh local-changes-overwritten ([`pitfalls/chezmoi-update-blesh-local-changes-overwritten.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/chezmoi-update-blesh-local-changes-overwritten.md)) — 原始碼 clone 已搬出 chezmoi external 路徑,以解耦 `make install`

### 13. apt / yum (系統套件)

**Linux 的務實後盾**。對發行版打包良好的工具(夠新、可用、沒有顯著
的上下游分歧),role 使用 apt/yum。

**使用 apt/yum 的 role**(不完全列舉):

| Role | apt 套件 | yum 套件 |
|---|---|---|
| `base` | `git`、`git-lfs`、`curl`、`wget`、`ripgrep`、`fd-find`、`jq`、`tree`、`build-essential` | `git`、`git-lfs`、`curl`、`wget`、`jq`、`tree`、`gcc`、`gcc-c++`、`make` |
| `bash` | (Linux 上只有 `primary_shell=bash` 時走 brew) | — |
| `zsh` | `zsh` | `zsh`(或 RHEL 7 上的 ncurses-devel + 原始碼編譯) |
| `devtools` | `bat`、`gh`、`glab`、`eza`、`git-delta`、`htop`、`pandoc`、`tldr` 等(很多) | 類似子集 |
| `media_tools` | `ffmpeg`、`imagemagick`、`libimage-exiftool-perl`、`libvips-tools` | — |
| `networking_tools` | `nmap`、`arp-scan`、`mtr`、`iperf3`、`httpie`、`tcpdump` | 同(扣掉 `httpie`) |
| `coding_agents` | `libnotify-bin`(僅 Debian) | — |
| `lazyvim_deps` | (主要靠 mise + GitHub releases) | — |
| `auditd` | `auditd`、`audispd-plugins` | `audit` |
| `gui_apps_linux` | `cmake`、`pkg-config`、字型函式庫(Alacritty 編譯)、`libfuse2`、`copyq`、`playerctl`、`wmctrl`、`xdotool` | — |
| `docker` | `uidmap`、`dbus-user-session`、`fuse-overlayfs`、`slirp4netns`、`iptables`(rootless 前置) | — |
| `iac_tools` | `azure-cli`、`terraform`、`opentofu`(透過廠商 apt repo) | — |
| `nerdfonts` | `fontconfig` | `fontconfig` |
| `python_uv_tools` | `libffi-dev`、`libyaml-dev`、`python3-dev`(Ruby + ansible-cryptography 編譯依賴) | `libffi-devel`、`libyaml-devel`、`python3-devel` |

**管理中的廠商 apt repo**(需要 GPG key + sources.list.d 條目):

| Repo | 用於什麼 |
|---|---|
| `apt.releases.hashicorp.com` | terraform |
| `packages.microsoft.com` | azure-cli、vscode |
| `cli.github.com/packages` | gh |
| `gitlab.com/api/v4/projects/.../packages/debian` | glab |
| `pkgs.gierens.de` | eza |
| `ngrok-agent.s3.amazonaws.com` | ngrok |
| `apt.releases.opentofu.org` | opentofu(Cloudsmith) |
| PPA `ppa:lazygit-team/release` | lazygit |
| PPA `ppa:appimagelauncher-team/stable` | AppImageLauncher |

**升級**:`scripts/upgrade_tools.sh` **不**涵蓋。依賴 repo 流程外的
`sudo apt upgrade` / `sudo yum update`。這是刻意的落差——發行版升級是
系統管理員的決定,不是 dotfiles 的決定。

**新增 apt/yum 套件**:在相關 role 的 `tasks/main.yml` 加一個
`ansible.builtin.apt` / `ansible.builtin.yum` task,用 `os_family` 控管。
永遠 `become: true` + `tags: [sudo]`(讓 noRoot 模式優雅跳過),
若工具有廣泛用途,考慮替 noRoot 路徑加一個使用者層級 fallback。

---

## 多機制工具 + 原因說明 {#multi-mechanism-tools--rationale}

安裝路徑因 OS / 架構 / role-feature-flag 而異的工具,以及原因說明。

| 工具 | 機制分派 | 為什麼 |
|---|---|---|
| **uv** | Bootstrap:curl。之後:依 binary 路徑分派 `brew upgrade uv` vs `uv self update` | brew 安裝會釘住版本到 versioned Cellar — `uv self update` 在那裡 no-op。Role + upgrade script 中的鏡像邏輯讓兩條路徑都能用。見 [pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md) |
| **OpenCode** | 兩個 OS 都走 curl-installer(2026-05 起) | 過去 macOS 是 brew tap(`anomalyco/tap`),但 formula 版本落後 + Cellar 釘版本讓 `opencode upgrade` 失效。統一到官方 installer + `--no-modify-path`。見 `coding_agents/tasks/main.yml` `# === OpenCode` 區塊 |
| **OpenAI Codex CLI** | macOS:brew cask;Linux:npm `@openai/codex` | macOS 有 brew 的 `.app`(較豐富);Linux 只出 npm CLI |
| **Gemini CLI** | macOS:brew formula `gemini-cli` → npm fallback;Linux:npm | brew formula 可用性不穩 |
| **Specstory** | macOS:brew tap → GitHub release fallback;Linux:GitHub release tarball | brew formula 可用性 + 版本新鮮度 |
| **CodexBar** | macOS:brew tap(僅 arm64);Linux:Linuxbrew → GitHub release | arm64 專屬套件 |
| **td** / **sidecar** | macOS:brew tap;Linux:Linuxbrew → GitHub release | 同維護者(`marcus/tap`);Linuxbrew 存在時走快路 |
| **Ollama** | 永遠 brew formula(CLI);`installAiDesktopApps + installLlmTools` 時 brew cask `ollama-app`;Linux:`curl ollama.com/install.sh` | CLI vs GUI 切分;廠商 installer 是 Linux 標準路徑 |
| **fzf** | macOS:`lazyvim_deps` brew。Linux:chezmoi external + `~/.fzf/install --bin` | macOS 用 brew 沒問題;Linux 拿到最新的 git tip |
| **bash** | 永遠有系統 bash;macOS 上只有 `primary_shell="bash"` 時才裝 homebrew bash 5.x | macOS 出貨 bash 3.2(GPL2 vintage);brew bash 5 只在使用者真的想當登入 shell 時才需要 |
| **gh** | macOS:brew(透過 `devtools`);Linux:廠商 apt repo → 使用者 tarball fallback | brew 是 macOS 標準;廠商 apt repo 是 Linux 標準 |
| **tmux** | macOS:brew;Linux:apt → 系統版本 < 3.3 時 `nelsonenzo/tmux-appimage` | `display-menu` popup 需要 3.3+ — 見 AGENTS.md tmux hard invariant |
| **Discord** | macOS:brew cask;Linux:flatpak(預設)或 `.deb`,由 `discordChannel` 選 | apt 沒有 Discord;flatpak 沙箱化且最新,`.deb` 給討厭 flatpak 的人 |
| **just**、**starship**、**zoxide**、**direnv** | macOS:brew;Linux:廠商 curl-installer | Linux 發行版套件對這些快速迭代的工具太舊 |
| **Neovim** | macOS:brew(`state: latest`);Linux:apt → GitHub release tarball → 使用者 fallback → oldEL 上的 `neovim/neovim-releases` | 最低版本 0.11.2 對大多數發行版太新;政策上不用 snap |
| **tree-sitter-cli** | npm 透過 mise(優先,timeout 180)→ cargo fallback | npm 比較快;cargo 需要 libclang 才能編譯。兩條路徑產生同一份 binary |
| **bw (Bitwarden CLI)** | npm 全域(優先)或系統 npm fallback | 永遠是 npm,分派是 mise-npm vs 系統-npm |

**新增多機制分派工具**:每個 OS 優先**一個**主要機制,最多**一個**
fallback。多層 fallback 會增加實際沒人會跑的測試組合(5 層 × 5 OS 變體
= 25 格)。猶豫時寫最簡單的版本,只在實際主機壞了才加 fallback。

---

## Fallback 鏈

值得記住的串接式 fallback 模式:

| 工具 | 鏈 |
|---|---|
| **mise binary** | curl `https://mise.run`(優先)→ 直接從 `mise.jdx.dev/mise-latest-linux-${arch}` 下載 → musl 變體(glibc < 2.28 時強制) |
| **Neovim (Linux)** | apt → 太舊則 GitHub release tarball(`/opt/nvim` + symlink)→ 使用者 tarball 到 `~/.local` → `neovim-releases` 分支(oldEL glibc 2.17 重建) |
| **base/devtools/networking_tools 中大多數 Linux CLI** | apt/yum(sudo)→ 使用者層級 GitHub release musl tarball 到 `~/.local/bin`。部分有架構專屬 brew-on-aarch64 分支(`eza`、`git-delta`) |
| **Rust (mise)** | 設定的 mirror → 官方 `static.rust-lang.org` → 在 oldEL 上:直接 `rustup-init` |
| **Cursor `.deb` (Linux)** | `get_url` 配 retries=4(大檔,GFW-prone)— 單一機制但重試多次 |
| **Bitwarden Desktop (Linux)** | snap → `.deb` fallback |
| **CodexBar / td / sidecar / RTK / specstory / llmfit** | Linuxbrew → GitHub release tarball |
| **uv (升級端)** | 檢查 binary 路徑 → `brew upgrade uv` 或 `uv self update` |
| **Discord (Linux)** | flatpak(預設)→ `.deb`(由 `discordChannel` 選) |
| **tree-sitter-cli (Linux)** | `mise exec -- npm install -g tree-sitter-cli`(timeout 180)→ `cargo install tree-sitter-cli`(先裝 `libclang-dev`) |
| **Antigravity installer** | curl → 中途 `sed` patch 注入 `--skip-path --skip-aliases` → bash(避開 profile 改寫) |
| **just** | macOS brew → Linux:廠商 `curl install.sh` 配 `sudo` → 使用者層級 `--bin-dir ~/.local/bin` fallback |

**為什麼要 fallback**:noRoot Linux 主機、RHEL/CentOS 7(glibc 2.17、
沒現代 bottle、超老 zsh)、Apple Silicon Mac(部分 brew formula 沒
arm64 bottle)、中國鏡像中斷。

---

## 覆蓋落差 (install-only,沒有自動化升級) {#coverage-gaps-install-only-no-automated-upgrade}

`chezmoi apply` 會裝但**沒有 `upgrade_tools.sh` 類別會刷新**的工具。
這些工具一旦安裝就停在當時的版本,除非手動移除重裝。

| 類別 | 為什麼沒升級 | 如何刷新 |
|---|---|---|
| **GitHub-release 使用者層級 fallback**(~30 個工具 — 見 [§ 11](#11-github-release-下載-使用者層級-fallback)) | `creates:` 守衛讓 ansible 永遠不重下 | `rm ~/.local/bin/<tool>` 後 `chezmoi apply` |
| **Debian 上的廠商 apt-repo 套件**(terraform、azure-cli、vscode、opentofu、ngrok、PPA 的 lazygit) | 依賴本 repo 流程外的 `sudo apt upgrade` | `sudo apt update && sudo apt upgrade`(非 chezmoi 的職責) |
| **Docker 便利腳本安裝** | 沒有升級目標 | 重跑 `curl get.docker.com \| sh` |
| **OrbStack** | macOS brew cask | 由 `cat_brew --cask --greedy` 涵蓋 |
| **Cursor `.deb`** / **Discord `.deb`** / **VSCode (Microsoft apt)** | apt 端,不是 chezmoi 端 | apt 升級 |
| **Zen Browser AppImage** / **AppImageLauncher Lite** | 一次性下載,`creates:` 守衛 | 刪 AppImage 後重 apply |
| **Hack Nerd Font** | `latest` URL,沒追版本 | 刪字型目錄後重 apply |
| **fontconfig / libfuse2 / libnotify-bin / playerctl / wmctrl / xdotool** | 系統套件,沒升級自動化 | apt 升級 |
| **auditd rules** | 設定檔,不是有版本的「工具」 | 編輯 rule 模板後重 apply |
| **claude-hud / LazyVim plugins / TPM plugins / pre-commit / tldr cache / gh extensions** | **被** `cat_plugins` 涵蓋 | `just upgrade-plugins` |

**為什麼這很重要**:在 Linux 主機上跑 `just upgrade-all` 的開發者拿到
brew + mise + uv + npm + cargo + dotnet + gem + flatpak + agents +
plugins 的推進。但 ~30 個 GitHub-release-installed CLI(其中很多廣泛
使用:ripgrep、fd、jq、git-delta、lazygit 等)永遠釘在安裝時間。
這部分被以下事實**部分緩解**:

- 這些工具在 **macOS** 上都走 brew,而 `cat_brew` 涵蓋
- **非 noRoot Linux** 上,發行版套件可以在 repo 流程外被 apt 升級
- 落差在 **noRoot Linux** 上最尖銳,因為 GitHub releases 是唯一安裝
  路徑,而且沒有升級自動化

**`cat_agents` 上的覆蓋落差**:只有 `claude / opencode / cursor-agent
/ ollama / llmfit / rtk / specstory` 拿到 self-update-then-curl 迴圈。
**漏掉**:`agy`(Antigravity)、`codexbar`、`td`、`sidecar`、
`specify-cli`、`openchamber`、`codex` — 這些依賴 brew / uv / npm
類別。

**backlog 追蹤**:還沒有正式條目,但在 `scripts/upgrade_tools.sh`
加一個 `releases` 類別(稽核已安裝 binary 對最新 GitHub tag,提示
是否刷新)會關閉這個落差。當前類別清單見
[upgrades.md](upgrades.md)。

---

## 工具索引 (A–Z) {#tool-index-az}

> 字母序查詢。對於有多條安裝路徑的工具，第一條為主要路徑；其餘以 ` / `
> 分隔列在同一格內。

| 工具 | macOS | Linux | Role |
|---|---|---|---|
| **aerospace** | brew cask(`nikitabobko/tap`) | n/a | Brewfile.darwin |
| **agy** / **agyc**(Antigravity CLI) | curl `antigravity.google/cli/install.sh` | 同 | coding_agents |
| **alacritty** | brew cask | cargo 編譯(apt 依賴) | Brewfile.darwin / gui_apps_linux |
| **alt-tab** | brew cask | n/a | Brewfile.darwin |
| **anki** | brew cask | n/a | Brewfile.darwin |
| **ansible-core** | uv tool install | uv tool install | bootstrap |
| **antigravity**(IDE) | brew cask | 佔位 | Brewfile.darwin |
| **applite** | brew cask | n/a | Brewfile.darwin |
| **AppImageLauncher** | n/a | PPA → GitHub `.deb` → Lite AppImage | gui_apps_linux |
| **apprise** | uv tool | uv tool | python_uv_tools |
| **arc** | brew cask | n/a | Brewfile.darwin |
| **arp-scan** | brew | apt/yum | networking_tools |
| **atuin** | brew | curl `setup.atuin.sh` | atuin |
| **azure-cli** | brew | Microsoft apt repo → uv tool fallback | iac_tools |
| **azure-cost-cli**(`azure-cost`) | `dotnet tool install --global` | 同 | dotnet_tools |
| **bandwhich** | brew | GitHub release musl | networking_tools |
| **bash**(5.x) | brew(`primary_shell="bash"` 時) | 系統 | bash |
| **bat** | brew | apt + `/usr/bin/bat` symlink → GitHub musl | base/devtools |
| **bats-core** | brew | apt → GitHub `install.sh` | devtools |
| **Bitwarden CLI**(`bw`) | `mise exec -- npm install -g @bitwarden/cli` | 同 | bitwarden |
| **Bitwarden Desktop** | brew cask | snap → `.deb` | bitwarden |
| **btop** | brew | apt → GitHub release | devtools |
| **build-essential** | n/a | apt | bootstrap(Linux) |
| **bun** | mise | mise | mise |
| **cargo-update** | cargo install(`cat_cargo` 的 bootstrap) | 同 | rust_cargo_tools |
| **chatgpt** | brew cask(arm64) | n/a | Brewfile.darwin |
| **Claude Code** | brew cask `claude-code` | curl `claude.ai/install.sh` → `~/.claude/local/bin/claude` | coding_agents |
| **claude-hud** | role 內跑 python 輔助 | 同 | coding_agents |
| **cloudflared** | brew | GitHub `.deb`/binary / `.rpm` | networking_tools(tunnel) |
| **CMux** | brew cask | n/a | Brewfile.darwin |
| **CodexBar** | brew cask `codexbar`(arm64,tap `steipete/tap`) | Linuxbrew → GitHub release | coding_agents |
| **codex-app** | brew cask(arm64) | n/a | Brewfile.darwin |
| **codex**(OpenAI Codex CLI) | brew cask `codex` | `mise exec -- npm install -g @openai/codex` | coding_agents |
| **CodeIsland** | brew cask(`wxtsky/tap`) | n/a | Brewfile.darwin |
| **CopyQ** | n/a | apt | gui_apps_linux |
| **coreutils** | brew | (GNU coreutils 透過 apt;macOS 透過 brew) | devtools |
| **copyparty** | uv tool | uv tool | python_uv_tools |
| **curl** | 系統 | apt/yum | base + bootstrap |
| **cursor**(IDE) | brew cask | `.deb` 來自 `cursor.com/api/download` | Brewfile.darwin / gui_apps_linux |
| **cursor-agent**(CLI) | curl `cursor.com/install` | 同 | coding_agents |
| **dasel** | brew | release | devtools |
| **dbeaver-community** | brew cask | n/a | Brewfile.darwin |
| **diffnav** | brew | GitHub release | devtools |
| **direnv** | brew | apt 或 curl-installer | devtools |
| **discord** | brew cask | flatpak(預設)/ `.deb` | Brewfile.darwin / gui_apps_linux |
| **docker** | brew cask `orbstack` | `curl get.docker.com` rootless | docker |
| **doggo** | brew | GitHub release | networking_tools |
| **dotenv**(python-dotenv[cli]) | uv tool | uv tool | python_uv_tools |
| **dotnet** | mise | mise | mise |
| **duckdb** | brew | GitHub release | devtools |
| **exiftool** | brew | apt(`libimage-exiftool-perl`) | media_tools |
| **eza** | brew | gierens.de apt repo → GitHub musl → brew aarch64 | devtools |
| **fastfetch** | brew | (Linux release 視情況) | devtools |
| **fd** | brew | apt(`fd-find` + symlink)→ GitHub release | base |
| **ffmpeg** | brew | apt | media_tools |
| **figlet** | brew | (apt 視情況) | devtools |
| **font-hack-nerd-font** | brew cask | GitHub release Hack.zip → `~/.local/share/fonts` | nerdfonts |
| **fontconfig** | (系統) | apt/yum | nerdfonts |
| **freeze** | brew | GitHub release | devtools |
| **fzf** | brew(透過 `lazyvim_deps`) | chezmoi external + `~/.fzf/install --bin` | lazyvim_deps + externals |
| **gawk** | brew | apt/yum | bash |
| **gcc / gcc-c++ / make** | (Xcode CLT) | apt(`build-essential`)/ yum | base + bootstrap |
| **gemini**(Gemini CLI) | brew formula `gemini-cli` → npm fallback | `mise exec -- npm install -g @google/gemini-cli` | coding_agents |
| **gh** | brew | 廠商 apt(.deb)→ GitHub tarball | base/devtools |
| **gh-dash** | `gh extension install dlvhdr/gh-dash` | 同 | devtools |
| **gh-notify** | `gh extension install meiji163/gh-notify` | 同 | devtools |
| **gh-select** | `gh extension install remcostoeten/gh-select` | 同 | devtools |
| **git** | brew | apt/yum | base |
| **git-delta** | brew | `.deb`(x86_64)→ brew aarch64 → GitHub musl 使用者 | devtools |
| **git-filter-repo** | uv tool | uv tool | python_uv_tools |
| **git-graph** | brew | GitHub release(僅 x86_64) | devtools |
| **git-lfs** | brew | apt/yum → GitHub release | base |
| **gitleaks** | brew | GitHub release | security_tools |
| **glab** | brew | 廠商 apt(.deb)→ GitHub tarball | devtools |
| **glow** | brew | GitHub release tarball | devtools |
| **go** | mise(`go = "latest"`) | 同左(mise) | mise(`installExtraRuntimes`) |
| **google-drive** | brew cask | n/a | Brewfile.darwin |
| **github-copilot-cli**(`@githubnext/github-copilot-cli`) | npm 全域 | `mise exec -- npm install -g` | coding_agents |
| **gping** | brew | GitHub release musl | networking_tools |
| **grammarly-desktop** | brew cask | n/a | Brewfile.darwin |
| **grc** | brew | apt | devtools |
| **gum** | brew | GitHub release | devtools |
| **Homebrew** | curl installer | 同(Linux,有控管) | bootstrap |
| **htop** | brew | apt | devtools |
| **httpie** | brew | apt(Debian) | networking_tools |
| **imagemagick** | brew | apt | media_tools |
| **輸入法**(`mcbopomofo`、`squirrel`) | brew cask | (Debian)apt `ibus-rime` | input_method |
| **iperf3** | brew | apt/yum | networking_tools |
| **jnv** | brew | release | devtools |
| **jq** | brew | apt/yum → GitHub release | base |
| **jupyterlab**(`jupyter-lab`) | uv tool(配 notebook、ipykernel 等) | uv tool | python_uv_tools |
| **just** | curl `just.systems/install.sh`(永遠) | 同 | base |
| **lazygit** | brew(透過 `lazyvim_deps`) | PPA → GitHub release | lazyvim_deps |
| **libnotify-bin** | n/a | apt(Debian) | coding_agents |
| **libfuse2** | n/a | apt | gui_apps_linux |
| **litellm[proxy]**(`litellm`) | uv tool(python 3.13) | uv tool | llm_tools |
| **llmfit** | brew formula | curl `llmfit.axjns.dev/install.sh` | llm_tools |
| **lnav** | brew | apt/release | devtools |
| **lolcat** | brew | (apt) | devtools |
| **maccy** | brew cask | n/a | Brewfile.darwin |
| **marimo** | uv tool(`[recommended,mcp]`) | uv tool | python_uv_tools |
| **mas** | brew(共用 Brewfile,僅 macOS) | n/a | Brewfile.tmpl |
| **mise** | curl `mise.run` | curl `mise.run` → 直接 binary → musl 變體 | bootstrap |
| **mlflow** | uv tool | uv tool | python_uv_tools |
| **models** | brew formula | Linuxbrew → cargo `modelsdev` | llm_tools |
| **mtr** | brew | apt/yum | networking_tools |
| **nmap** | brew | apt/yum | networking_tools |
| **neovim** | brew(`state: latest`) | apt → GitHub release → 使用者 → oldEL 分支 | neovim |
| **ngrok** | brew cask | 廠商 apt repo → 使用者 tgz / RedHat tgz | networking_tools(tunnel) |
| **node** | brew(透過 `lazyvim_deps`) | mise | mise + lazyvim_deps |
| **obsidian** | brew cask | n/a | Brewfile.darwin |
| **ollama** | brew formula `ollama`(CLI)+ cask `ollama-app`(GUI) | curl `ollama.com/install.sh` | llm_tools |
| **openchamber**(`@openchamber/web`) | npm 全域 | `mise exec -- npm install -g` | coding_agents |
| **opencode** | curl `opencode.ai/install`(`--no-modify-path`)→ `~/.opencode/bin/opencode` | 同 | coding_agents |
| **opencode-desktop** | brew cask | n/a | Brewfile.darwin |
| **opentofu**(`tofu`) | brew formula | Cloudsmith apt repo → GitHub release | iac_tools |
| **OrbStack** | brew cask | n/a | docker |
| **pandoc** | brew | apt | devtools |
| **playerctl / wmctrl / xdotool** | n/a | apt | gui_apps_linux |
| **pre-commit** | `uv tool install --python 3.13` | 同 | security_tools |
| **procps** | (系統) | apt | bootstrap(Linux) |
| **pueue** | brew formula | `cargo install pueue --locked` + systemd user unit | rust_cargo_tools |
| **python-dotenv[cli]** | uv tool | uv tool | python_uv_tools |
| **raycast** | brew cask | n/a | Brewfile.darwin |
| **rclone** | brew | 官方 installer 或 GitHub | devtools — macOS 的 `rclone mount` 還需要 **macFUSE**（macOS 26+ 需 5.x），手動安裝且**不由本 repo 管理**（需重開機 + GUI 授權）；brew rclone ≥1.73 已內建 `mount`，所以瓶頸不是 binary（[pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/macfuse-too-old-unsupported-macos-version-rclone-mount.md)） |
| **readability-cli**(`readable`) | npm 全域 | `mise exec -- npm install -g` | js_cli_tools |
| **recon** | cargo install(git source) | 同 | rust_cargo_tools |
| **ripgrep** | brew | apt/yum → GitHub release | base |
| **ruby** | mise | mise(noRoot 跳過) | mise |
| **rust** | mise | mise → rustup-init → `static.rust-lang.org` fallback | mise + rust_cargo_tools |
| **rustscan** | brew | GitHub release | networking_tools |
| **scroll-reverser** | brew cask | n/a | Brewfile.darwin |
| **sesh** | brew | GitHub release | devtools |
| **shellcheck / shfmt** | brew | apt 或 release | devtools |
| **sidecar** | brew tap `marcus/tap` | Linuxbrew → GitHub release | coding_agents |
| **specify-cli** | `uv tool install` 從 git | 同 | coding_agents |
| **specstory** | brew tap `specstoryai/tap` → GitHub release | GitHub release tarball | coding_agents |
| **speedtest**(Ookla) | brew(tap `teamookla/speedtest`) | `install.speedtest.net` | networking_tools |
| **spotify** | brew cask | n/a | Brewfile.darwin |
| **sqlit-tui[ssh]** | uv tool | uv tool | python_uv_tools |
| **starship** | brew | curl `starship.rs/install.sh` | starship |
| **super-productivity** | brew cask | n/a | Brewfile.darwin |
| **superfile** | brew | installer/release | devtools |
| **superset** | brew cask(arm64) | n/a | Brewfile.darwin |
| **tailscale**(CLI) | 由 `tailscale-app` cask 的 wrapper 提供(`/usr/local/bin/tailscale` → app;無 formula) | (Linux:repo 外的系統 pkg) | Brewfile.darwin |
| **tailscale-app** | brew cask(pkg 同時安裝 `/usr/local/bin/tailscale` CLI wrapper) | n/a | Brewfile.darwin |
| **tailspin**(`tspin`) | brew | release | devtools |
| **taplo** | brew | apt+release | devtools |
| **td** | brew tap `marcus/tap` | Linuxbrew → GitHub release | coding_agents |
| **television**(`tv`) | brew | apt+release | devtools |
| **terminal-notifier** | brew | n/a | coding_agents(macOS) |
| **terraform** | brew(`hashicorp/tap`) | HashiCorp apt repo → 使用者 zip | iac_tools |
| **the-unarchiver** | brew cask | n/a | Brewfile.darwin |
| **thefuck** | brew | uv tool(python 3.11 distutils) | devtools |
| **tldr** | (macOS 透過 brew 用 `tlrc`) | 系統 npm 或 `mise exec -- npm install -g tldr` | devtools |
| **tlrc** | brew | (Linux 改用 npm `tldr`) | devtools |
| **tmux** | brew | apt → < 3.3 時 tmux-appimage | devtools |
| **tmuxinator** | gem | gem | ruby_gem_tools |
| **tmuxp** | uv tool | uv tool | python_uv_tools |
| **toilet** | brew | (apt) | devtools |
| **tree** | brew | apt/yum | base |
| **tree-sitter** / **tree-sitter-cli** | brew | mise-npm → cargo fallback | lazyvim_deps |
| **trippy**(`trip`) | brew | apt/release | networking_tools |
| **try-cli**(`try`) | gem | gem | ruby_gem_tools |
| **uv** | curl `astral.sh/uv/install.sh` | 同 | bootstrap;`python_uv_tools` 自我升級分派 |
| **vhs** | brew | GitHub release | devtools |
| **visidata**(`vd`) | uv tool(配 pandas、pyarrow) | uv tool | python_uv_tools |
| **vips** | brew | apt(`libvips-tools`) | media_tools |
| **visual-studio-code** | brew cask | Microsoft apt repo | Brewfile.darwin / gui_apps_linux |
| **warp** | brew cask | n/a | Brewfile.darwin |
| **wget** | brew | apt/yum | base |
| **witr** | brew | (release) | devtools |
| **workmux** | brew(tap `raine/workmux`) | GitHub release `.tar.gz` | devtools |
| **worktrunk** | brew | GitHub release | devtools |
| **xonsh** | uv tool(配 xontribs) | uv tool | python_uv_tools |
| **yazi** | brew | Linuxbrew/GitHub release | devtools |
| **yq** | brew | release | devtools |
| **yt-dlp** | uv tool | uv tool | python_uv_tools |
| **Zen Browser** | n/a | GitHub release AppImage → `~/Applications/zen.AppImage` | gui_apps_linux |
| **zellij** | brew | GitHub release | devtools |
| **zoxide** | brew | curl 官方 installer | devtools |
| **zsh** | brew | apt/yum / 原始碼編譯(RHEL 7) | zsh |

> 未列出的工具:`oh-my-zsh`、`oh-my-bash`、`zsh-autosuggestions`、
> `zsh-syntax-highlighting`、`zsh-completions`、`zsh-vi-mode`、
> `ble.sh`、`TPM`、`toolkami.rb` — 這些以 **chezmoi externals** 形式存在
> ([§ 12](#12-chezmoi-externals-週期刷新-git檔案抓取)),不是「PATH 上的
> binary」。

---

## 新增工具決策樹 {#decision-tree-for-new-tools}

```
工具需要在 ansible 跑之前就存在嗎?
├── 是 → Bootstrap 腳本(run_once_before_*)— 僅在絕對必要時
└── 否 → 繼續

它是 runtime / 語言直譯器(node、ruby、python、rust、go、dotnet)?
├── 是 → mise(dot_config/mise/config.toml.tmpl)— 除了 python(用 uv)
└── 否 → 繼續

是 Python CLI 工具嗎?
├── 是 → uv(附加到 python_uv_tools/defaults/main.yml)
│         · LLM 相關走 llm_tools/defaults/main.yml
│         · 需要 gcc ≥ 9?設 needs_modern_gcc: true
│         · 會寫伴隨 binary?同時設 with_executables_from 與 extra_binaries
└── 否 → 繼續

是 Node/JS CLI 工具嗎?
├── 是 → npm 透過 mise(附加到 js_cli_tools/defaults/main.yml)
│         · Agent CLI?改寫到 coding_agents/tasks/main.yml
└── 否 → 繼續

是 crates.io 上發佈良好的 Rust crate?
├── 是 → cargo(rust_cargo_tools/defaults/main.yml cargo_tools 條目)
│         · 需要編譯依賴或 git-source?在 tasks/main.yml 中 hard-code
└── 否 → 繼續

是 Ruby gem?
├── 是 → gem(ruby_gem_tools/defaults/main.yml)
│         · noRoot Linux 上自動跳過
└── 否 → 繼續

是 .NET 全域工具?
├── 是 → dotnet tool(dotnet_tools/defaults/main.yml)
└── 否 → 繼續

工具是 coding agent CLI(廠商出貨、有自己的 installer)?
├── 是 → curl-installer 寫進 coding_agents/tasks/main.yml
│         · 對齊現有模式(Claude / OpenCode / Cursor)
│         · 傳 --no-modify-path 或對等(別改 shell rc)
│         · 加進 scripts/upgrade_tools.sh 的 cat_agents
│         · 更新 AICAP SSOT(dot_config/shell/04_ai_agents.sh)+
│           四個 Python AGENT_CONFIG dict(見 AGENTS.md hard invariant)
└── 否 → 繼續

是 macOS 出貨的 GUI app?
├── 是 → brew cask 寫進 Brewfile.darwin.tmpl
│         · AI 類用 installAiDesktopApps 控管
└── 否 → 繼續

是 macOS 出貨的 CLI?
├── 是 → brew formula 寫進相關 role 的 tasks/main.yml
│         · 在同 role 加 Linux fallback(apt 或 GitHub release)
│         · 考慮是否 macOS-only 就好(例如 terminal-notifier)
└── 否 → 繼續

是 Linux-only、發行版打包?
├── 是 → apt / yum 寫進相關 role 的 tasks/main.yml
│         · become: true + tags: [sudo]
│         · 為 noRoot 加使用者層級 GitHub-release fallback
└── 否 → 繼續

是 Linux-only、廠商出貨(有自己的 install.sh)?
├── 是 → curl-installer 寫進相關 role
│         · 用 creates: 守衛
│         · 如果 binary 落在 ~/.local/bin 以外,在
│           dot_config/shell/00_exports.sh.tmpl 加 PATH 前置
└── 否 → 繼續

GitHub release tarball(其他一切的最可靠路徑):
└── 從 devtools/tasks/main.yml 複製標準模式
    · block: + rescue:(廠商會出包)
    · 在 get_url 上 retries: 3, delay: 5, timeout: 120
    · 透過 target_architecture 計算架構
    · 解壓到 ~/.local/bin(使用者)或 /usr/local/bin(sudo + tags: [sudo])
    · ⚠️ 這個 binary 不會被自動升級(見 § 覆蓋落差)
```

**新增工具時其他要做的事**:

1. 工具若出貨 shell completion(`<tool> completion zsh|bash`),
   在 `scripts/generate_completions.sh` 加一條 `regen` row(按 AGENTS.md
   cross-file rule)
2. 若工具是新的自家 CLI(自製,在 `dot_dotfiles/bin/`),按
   `docs/zsh/zsh-completions.md` Section F 的 completion 決策流程做
   (兩份手寫 completion 檔 + Section F 表格的 row + `docs/shells/aliases.md`
   的 row)
3. 若工具有特殊的升級故事(self-update 子命令等),在
   [`upgrades.md`](upgrades.md) 加類別或擴充既有類別
4. 若工具取代了另一個工具,把舊路徑加到 `.chezmoiremove`
5. 若工具是新的 alias / shell function,在 `docs/shells/aliases.md` 加一條 row
   (按 AGENTS.md cross-file rule)

---

## 交叉參考

**其他相關文件**:

- [`upgrades.md`](upgrades.md) — 升級面參考(本文是安裝面)
- [`architecture.md`](architecture.md) — Repo 布局 + 安裝流程階段
- [`bootstrap.md`](bootstrap.md) — Bootstrap 腳本深度說明
- [`uv-bootstrap.md`](uv-bootstrap.md) — 為什麼 uv 很特別
- [`ansible_customization.md`](ansible_customization.md) — 每主機 ansible 變數覆蓋
- [`config-conventions.md`](config-conventions.md) — 部署的設定檔住在哪
- [`testing.md`](testing.md) — 如何驗證工具裝對了

**相關的 AGENTS.md hard invariants**:

- "Install vs upgrade is split on purpose" — 永遠不要 `state: latest`
- "`with_executables_from:` entries MUST also declare `extra_binaries:`"
- "primaryShell choice gates `chsh` only — both shells always deploy"
- "AI agent autodetect order or AICAP_*_MODEL defaults" — 只編輯 `04_ai_agents.sh`
- "Tmux ≥ 3.3 required" — 見 [§ 多機制工具](#multi-mechanism-tools--rationale) 的 `tmux` 條目

**與安裝路徑相關的過往 pitfall**:

- [`uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md) — uv 為何需要 brew-vs-curl 分派
- [`uv-tool-install-creates-guard-misses-executables-from.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-tool-install-creates-guard-misses-executables-from.md) — `extra_binaries:` 必要性
- [`ansible-js-cli-tools-old-system-node.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-js-cli-tools-old-system-node.md) — Linux 上 npm 為何走 mise
- [`ansible-missing-sudo-tag.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-missing-sudo-tag.md) — `tags: [sudo]` 慣例
- [`centos7-neovim-apt-register-defined.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/centos7-neovim-apt-register-defined.md) — neovim user-fallback gate bug
- [`tmux-appimage-terminfo-not-found.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-appimage-terminfo-not-found.md) — tmux-appimage 注意事項
- [`opencode-docker-opentui-glibc-loader-missing.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/opencode-docker-opentui-glibc-loader-missing.md) — opencode 容器變體
- [`chezmoi-update-blesh-local-changes-overwritten.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/chezmoi-update-blesh-local-changes-overwritten.md) — 後置 hook 改動工作樹時 externals 會漂移

**與安裝路徑相關的 backlog 條目**:

- [`mise-runtime-gating.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/mise-runtime-gating.md) — 細粒度的每主機 runtime 控管
- [`devtools-role-split.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/devtools-role-split.md) — 拆開巨型 role
- [`lean-bundle-init-ux.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/lean-bundle-init-ux.md) — bundle 預設 + 決策樹 SSOT
- [`opencodebox-wrapper.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/opencodebox-wrapper.md) — 容器化 opencode wrapper
