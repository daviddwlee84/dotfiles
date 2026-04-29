# 專案維護備忘錄 (Cheatsheet)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

維護此 dotfiles 儲存庫所用的所有 CLI 命令快速參考。

> 大部分命令都有 `just` 捷徑。執行 `just`（不加參數）即可列出每個可用的 recipe。

---

## 目錄

- [just](#just)
- [chezmoi](#chezmoi)
- [Ansible](#ansible)
- [Brew Bundle](#brew-bundle)
- [Docker](#docker)
- [Pre-commit & Gitleaks](#pre-commit--gitleaks)

---

## just

```bash
just          # List all available recipes
just info     # Show system info and installed tool versions
just status   # git status
just diff     # git diff
just check    # Full lint + dry-run (run before commits)
```

---

## chezmoi

| 命令 | `just` 捷徑 | 說明 |
|---------|-----------------|-------------|
| `chezmoi diff` | `just chezmoi-diff` | 預覽會變更的內容 |
| `chezmoi apply` | `just chezmoi-apply` | 部署 dotfiles 並觸發 run script |
| `chezmoi apply --dry-run` | `just chezmoi-dry-run` | 不做任何變更地測試 apply |
| `chezmoi status` | `just chezmoi-status` | 顯示已修改 / 新增 / 移除的檔案 |
| `chezmoi edit <file>` | — | 編輯來源檔案（例如 `chezmoi edit ~/.zshrc`） |
| `chezmoi cd` | — | 跳到 chezmoi source 目錄 |
| `chezmoi init` | `just chezmoi-reinit` | 重新執行互動式 init 提示 |
| `chezmoi state delete-bucket --bucket=scriptState` | `just chezmoi-clear-scripts` | 重設 `run_once` 腳本狀態 |
| *(清除 + 套用)* | `just chezmoi-rerun-scripts` | 清除腳本狀態後重新 apply |

---

## Ansible

劇本 (playbook) 在 `chezmoi apply` 之後存放於 `~/.ansible/`（來源：`dot_ansible/`）。

```bash
cd ~/.ansible

# Full platform setup
ansible-playbook playbooks/macos.yml                    # macOS
ansible-playbook playbooks/linux.yml --ask-become-pass  # Linux (sudo)
ansible-playbook playbooks/base.yml                     # Core tools only

# Selective runs
ansible-playbook playbooks/macos.yml --tags "neovim,lazyvim_deps"
ansible-playbook playbooks/linux.yml --skip-tags "sudo"

# Dry run
ansible-playbook playbooks/macos.yml --check

# Syntax check (from repo root)
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
```

**`just` 捷徑：**

```bash
just ansible-syntax-check         # Check all playbooks
just ansible-base                 # Run base playbook
just ansible-macos                # Run macOS playbook
just ansible-linux                # Run Linux playbook
just ansible-tags "neovim,zsh"    # Run specific tags only
just ansible-check                # Dry run (--check)
just ansible-security             # security_tools tag only
```

### 可用的 Ansible Tag

| Tag | 說明 |
|-----|-------------|
| `base` | git、curl、ripgrep、fd、build tools |
| `zsh` | zsh、oh-my-zsh、外掛 |
| `starship` | Starship 跨 shell 提示字元 |
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf、lazygit、tree-sitter-cli、Node.js |
| `devtools` | bat、eza、delta、zoxide、tmux、sesh、zellij、btop、television、yazi 等 |
| `docker` | Docker / OrbStack |
| `nerdfonts` | Hack Nerd Font |
| `security_tools` | pre-commit、gitleaks |
| `homebrew` | macOS Homebrew 更新 *(僅 macOS)* |
| `coding_agents` | Claude Code、Cursor CLI、Gemini CLI 等 *(opt-in)* |
| `bitwarden` | Bitwarden CLI + Desktop *(opt-in)* |
| `python_uv_tools` | uv 管理的 CLI 工具 *(opt-in)* |
| `llm_tools` | Ollama、LiteLLM、llmfit *(opt-in)* |
| `rust_cargo_tools` | pueue 等，透過 cargo |
| `ruby_gem_tools` | try-cli、tmuxinator，透過 gem |
| `input_method` | McBopomofo + RIME *(僅桌面 + opt-in)* |
| `networking_tools` | nmap、doggo、httpie、bandwhich、rustscan 等 *(opt-in)* |

---

## Brew Bundle

GUI app 為 opt-in（在 `chezmoi init` 時設定 `installBrewApps = true`）。

```bash
# Check what's missing
brew bundle check --file=~/.config/homebrew/Brewfile
brew bundle check --file=~/.config/homebrew/Brewfile.darwin

# Install
brew bundle --file=~/.config/homebrew/Brewfile
brew bundle --file=~/.config/homebrew/Brewfile.darwin   # macOS casks + mas
brew bundle --file=~/.config/homebrew/Brewfile.linux    # Linuxbrew packages

# Edit (opens source file via chezmoi)
chezmoi edit ~/.config/homebrew/Brewfile.darwin
```

> 當 Brewfile 內容變更時，`chezmoi apply` 會自動觸發 Brew Bundle。

---

## Docker

用於在純淨 Ubuntu 映像檔上測試完整安裝流程。

| 命令 | 說明 |
|---------|-------------|
| `just docker-build` | 建置預設映像檔 (ubuntu_server) |
| `just docker-build-all` | 建置 server + desktop + china profile |
| `just docker-run` | 在 devbox 容器中啟動互動式 shell |
| `just docker-up` | 在背景啟動 devbox 容器 |
| `just docker-down` | 停止所有容器 |
| `just docker-test` | 在容器內執行完整測試套件 |
| `just docker-desktop` | 建置並進入 desktop profile |
| `just docker-china` | 建置並進入 china profile（中國鏡像） |
| `just docker-clean` | 移除所有 dotfiles 容器與映像檔 |

---

## Pre-commit & Gitleaks

> 一般性的 pre-commit 參考（其 virtualenv-per-hook 模型運作方式、`uv` 管理的 bootstrap Python，以及損壞的 hook env 疑難排解）請參閱 [`docs/tools/pre-commit.md`](../tools/pre-commit.md)。

```bash
# Setup
just pre-commit-install-tool   # Install pre-commit binary
just pre-commit-setup          # Install git hooks in repo

# Run
just pre-commit-run            # Run on staged files
just pre-commit-run-all        # Run on all files
just pre-commit-update         # Update hook versions
just pre-commit-uninstall      # Remove git hooks

# Secret scanning (specstory history + .claude/plans + .cursor/plans + .opencode/plans)
just gitleaks-scan             # Scan working tree for secrets
just gitleaks-scan-history     # Scan full git history
just check-secrets             # Check staged agent artifacts for secrets
just redact-secrets            # Auto-redact secrets in staged agent artifacts
just check-secrets-workdir     # Check working dir (not just staged)
just add-and-redact            # git add -A + redact + git add -A
# Legacy specstory-only aliases:
just check-specstory           # Check only .specstory files
just redact-specstory          # Redact only .specstory files
```
