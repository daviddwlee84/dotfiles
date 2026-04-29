# Ansible 自訂指南

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本文件說明如何自訂你的 dotfiles 中的 ansible 設定。

## 目錄結構 (Directory Structure)

執行 `chezmoi apply` 之後，ansible 檔案會被部署到 `~/.ansible/`：

```
~/.ansible/
├── ansible.cfg            # Ansible configuration (sets roles_path, inventory)
├── inventories/
│   └── localhost.ini      # Local inventory
├── playbooks/
│   ├── base.yml           # Cross-platform essentials
│   ├── linux.yml          # Linux-specific setup
│   └── macos.yml          # macOS-specific setup
└── roles/
    ├── base/              # git, curl, ripgrep, fd, etc.
    ├── homebrew/          # macOS Homebrew installation
    ├── neovim/            # Neovim with version check
    └── lazyvim_deps/      # fzf, lazygit, tree-sitter-cli
```

## 先決條件 (Prerequisites)

安裝 ansible 與所需的 collection：

```bash
# Install ansible with uv
uv tool install ansible-core

# Install community.general collection (for homebrew module)
ansible-galaxy collection install community.general
```

## 執行劇本 (Running Playbooks)

從 `~/.ansible/` 目錄執行（`ansible.cfg` 會自動設定 inventory 與 `roles_path`）：

### 完整安裝

```bash
cd ~/.ansible

# macOS
ansible-playbook playbooks/macos.yml

# Linux
ansible-playbook playbooks/linux.yml
```

### 特定 Tag

```bash
cd ~/.ansible

# Only install neovim
ansible-playbook playbooks/macos.yml --tags neovim

# Install neovim and its dependencies
ansible-playbook playbooks/macos.yml --tags "neovim,lazyvim_deps"
```

### 跳過 Tag

```bash
# Skip tasks requiring sudo (for non-admin users)
ansible-playbook playbooks/linux.yml --skip-tags sudo
```

### Dry Run

```bash
# Check what would change without applying
ansible-playbook playbooks/macos.yml --check

# Verbose output
ansible-playbook playbooks/macos.yml --check -v
```

## 可用的 Tag

| Tag | 說明 | 需要 Sudo |
|-----|-------------|---------------|
| `base` | 必備工具 (git、curl、ripgrep、fd、jq) | 僅 Linux |
| `homebrew` | macOS Homebrew 安裝 | 否 |
| `neovim` | Neovim 安裝（含版本檢查） | 僅 Linux |
| `lazyvim_deps` | LazyVim 相依套件 | 僅 Linux |
| `networking_tools` | 網路 CLI 工具 (nmap、mtr、httpie、gping、trippy 等) | 僅 Linux（部分） |
| `sudo` | 所有需要提權的工作 | 是 |

## 新增角色 (Adding New Roles)

1. 建立角色目錄結構：

```bash
mkdir -p ~/.ansible/roles/myrole/tasks
mkdir -p ~/.ansible/roles/myrole/defaults  # optional
```

2. 建立工作檔案 `~/.ansible/roles/myrole/tasks/main.yml`：

```yaml
---
- name: Install my package (macOS)
  when: ansible_os_family == "Darwin"
  community.general.homebrew:
    name: mypackage
    state: present

- name: Install my package (Debian/Ubuntu)
  when: ansible_os_family == "Debian"
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name: mypackage
    state: present
```

3. 將角色加進劇本：

```yaml
# In ~/.ansible/playbooks/macos.yml or linux.yml
roles:
  - role: myrole
    tags: [myrole]
```

## 把變更同步回 Chezmoi

在 `~/.ansible/` 中實驗變更後，把它們加回 chezmoi：

```bash
# Copy modified files back to chezmoi source
cp ~/.ansible/roles/myrole/tasks/main.yml ~/.local/share/chezmoi/dot_ansible/roles/myrole/tasks/main.yml

# Or use chezmoi re-add
chezmoi re-add ~/.ansible/roles/myrole/tasks/main.yml
```

## OS 偵測

用於 OS 偵測的 Ansible fact：

| Fact | macOS | Ubuntu/Debian |
|------|-------|---------------|
| `ansible_os_family` | Darwin | Debian |
| `ansible_distribution` | MacOSX | Ubuntu |
| `ansible_pkg_mgr` | homebrew | apt |

條件式範例：

```yaml
- name: macOS only task
  when: ansible_os_family == "Darwin"
  # ...

- name: Ubuntu only task
  when: ansible_distribution == "Ubuntu"
  # ...
```

## Sudo 處理

### Linux

大部分套件安裝都需要 sudo。相關工作會被標記 `sudo` tag：

```yaml
- name: Install package
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name: mypackage
```

若沒有 sudo 權限，請以 `--skip-tags sudo` 略過這些工作。

### macOS

Homebrew 以使用者身分執行，不需要 sudo。唯一例外是系統層級的變更。

## 疑難排解

### 語法檢查

```bash
ansible-playbook --syntax-check ~/.ansible/playbooks/base.yml
```

### Verbose 輸出

```bash
ansible-playbook ... -vvv
```

### 列出工作

```bash
ansible-playbook ... --list-tasks
```

### 列出 Tag

```bash
ansible-playbook ... --list-tags
```

### 常見故障

#### 執行已安裝的 CLI 時出現 `GLIBC_2.XX not found` (Ubuntu 22.04 / 較舊發行版)

**症狀** — ansible 角色安裝的 CLI 在啟動時失敗：

```
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tv)
```

**根本原因** — 工具的 `unknown-linux-gnu` target 下發布的 `.tar.gz` 或 `.deb` 是在 CI 映像檔（Ubuntu 24.04 / Debian 13）上建置的，其 glibc 比主機發行版內建的還新。Ubuntu 22.04 LTS 卡在 **glibc 2.35**，因此任何需要 glibc ≥ 2.36 的 binary 都會無法啟動。

**修正方式（自 Jammy hardening 補丁 (patch) 起已套用於本儲存庫）：** ansible 角色現在優先選用 musl asset 而非 gnu asset，當沒有安全的 musl asset 時才退回 Linuxbrew（或跳過並警告）。完整策略請參閱 [docs/linux-package-sources.md → GitHub binary asset selection policy](../linux-package-sources.md#github-binary-asset-selection-policy)。

**若你在本儲存庫設定的機器上仍看到此錯誤**，下列其中之一適用：

1. **PATH 上仍有先前 apply 留下的過時 gnu binary。** 新角色只在 `command -v <tool>` 檢查失敗時才下載 musl / brew，所以舊的損壞 binary 會短路掉安裝流程。移除它並重新執行 `chezmoi apply`：

   ```bash
   rm -f ~/.local/bin/tv /usr/local/bin/tv   # or whichever tool
   chezmoi apply
   ```

2. **該工具沒有上游 musl asset，且 Linuxbrew 未安裝。** 截至撰寫時受影響的工具：`tv`（所有架構）、`git-delta`（僅 arm64）、`eza`（僅 arm64）。角色會印出明確的 debug 訊息要你安裝 Linuxbrew。在 Debian / Ubuntu 上：

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
   chezmoi apply     # re-runs the role, brew-install branch taken this time
   ```

3. **新工具被加進角色時又用了 `unknown-linux-gnu`。** 新增下載 Rust / Go binary 的角色時，請優先選用 musl asset，並依上方連結的策略採用 brew-or-skip 備援。模式範例：`ripgrep` / `bat` / `fd` / `zellij` / `tailspin` / `lnav` / `trippy`。

#### 在某些主機上 `eza` 因為損壞的第三方 apt repo 而安裝失敗

請參閱 `dot_ansible/roles/devtools/tasks/main.yml` 中 `Add eza repository` 工作上的註解 — `deb.gierens.de` repo 偶爾會出現過期的 GPG 簽章。角色會容忍這個情況並跌落到 GitHub-release 備援，所以通常不需要手動修正。若連備援也失敗，移除損壞的 repo 檔案：

```bash
sudo rm -f /etc/apt/sources.list.d/gierens.list /etc/apt/keyrings/gierens.gpg
sudo apt update
chezmoi apply     # re-runs the role; GitHub-release fallback picks it up
```

## LazyVim 需求

LazyVim 需要：

- Neovim >= 0.11.2
- ripgrep（給 telescope live grep）
- fd（給 telescope file finder）
- Node.js（給 LSP server）
- tree-sitter-cli（給語法高亮）
- lazygit（選用，給 git 整合）
- fzf（選用，給模糊搜尋）

全部由 `base`、`neovim`、`lazyvim_deps` 角色安裝。
