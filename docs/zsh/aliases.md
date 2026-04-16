# Custom Aliases & Shell Functions

Quick reference for custom aliases and shell functions defined in this dotfiles repo.

> **Maintenance rule** (mirrored in `CLAUDE.md`): whenever you add, modify, or remove a custom alias or shell function, update this table — include the type (`alias` or `function`), source file (relative to repo root), and a one-line description.

---

## Table of Contents

- [Editor](#editor)
- [File Listing](#file-listing)
- [Navigation](#navigation)
- [Git](#git)
- [Tools Picker](#tools-picker)
- [Session Management](#session-management)
- [GitHub / GitLab](#github--gitlab)
- [AI Usage Tracking](#ai-usage-tracking)
- [Task Queue](#task-queue)
- [Networking](#networking)
- [Shell Utilities](#shell-utilities)
- [Package Managers & Runtime](#package-managers--runtime)

---

## Editor

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `v` | alias | `dot_config/zsh/10_aliases.zsh` | Open Neovim (`nvim`) |

---

## File Listing

> Provided by `eza` (modern `ls` replacement). Only active when `eza` is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ls` | alias | `dot_config/zsh/tools/26_eza.zsh` | Compact listing with icons, colors, git status |
| `la` | alias | `dot_config/zsh/tools/26_eza.zsh` | Long listing including hidden files, sorted dirs-first |
| `ll` | alias | `dot_config/zsh/tools/26_eza.zsh` | Long listing, sorted dirs-first (no hidden files) |
| `lt` | alias | `dot_config/zsh/tools/26_eza.zsh` | Tree view, 2 levels deep |
| `llt` | alias | `dot_config/zsh/tools/26_eza.zsh` | Long tree view, 3 levels deep |

---

## Navigation

> `cd` is only replaced when `zoxide` is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cd` | alias | `dot_config/zsh/tools/20_zoxide.zsh` | Smart `cd` via zoxide (`z`) with frecency-based matching |

---

## Git

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `gcam` | function | `dot_config/zsh/10_aliases.zsh` | `git add -A && git commit -m "<msg>"` |
| `gca` | alias | `dot_config/zsh/10_aliases.zsh` | `git commit --amend --no-edit` (keep existing message) |
| `gcam-amend` | function | `dot_config/zsh/10_aliases.zsh` | `git commit --amend -m "<msg>"` (replace message) |
| `gundo` | function | `dot_config/zsh/10_aliases.zsh` | Undo last commit → back to staged; prints undone commit message |
| `lg` | alias | `dot_config/zsh/tools/37_lazygit.zsh` | Open lazygit TUI |

---

## Tools Picker

> Requires `fzf`. Data file (`~/.config/docs/tools/cli-tools.md`) must be deployed via `chezmoi apply`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `tools-picker` | function | `dot_config/zsh/tools/11_tools_picker.zsh` | fzf picker for installed CLI tools; Enter pastes invocation to buffer, Ctrl+E executes (bound to `Alt+T`) |

---

## Session Management

> Requires `sesh` + `tmux`. `tsesh` also requires the `try-cli` Ruby gem.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `sesh-sessions` | function | `dot_config/zsh/tools/22_sesh.zsh` | fzf popup picker for all sesh sessions (also bound to `Alt+S`) |
| `sesh-here` / `shere` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | Connect sesh to current directory (creates session if missing) |
| `sesh-root` / `sroot` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | Connect sesh to current git root (falls back to `$PWD`) |
| `try-sesh` / `tsesh` | function / alias | `dot_config/zsh/tools/32_try.zsh` | Open a `try` ephemeral workspace and immediately connect via sesh |

---

## GitHub / GitLab

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ghget` | function | `dot_config/zsh/tools/41_github.zsh` | Download a subdirectory from a GitHub tree URL |
| `glcreate` | function | `dot_config/zsh/tools/42_gitlab.zsh` | Create a private GitLab repo under a group, set origin, and push |
| `glcreate-ai` | function | `dot_config/zsh/tools/42_gitlab.zsh` | Same as `glcreate` but uses an AI agent to auto-generate the description |

---

## AI Usage Tracking

> `cbu`/`cbc`/`cbca` require `codexbar`. `ccusage` requires `bun`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cbu` | alias | `dot_config/zsh/tools/40_codexbar.zsh` | Claude Code CLI usage stats (`codexbar usage --provider claude --source cli`) |
| `cbc` | alias | `dot_config/zsh/tools/40_codexbar.zsh` | Claude Code cost breakdown (`codexbar cost --provider claude`) |
| `cbca` | alias | `dot_config/zsh/tools/40_codexbar.zsh` | Cost breakdown across all providers (`codexbar cost`) |
| `ccusage` | alias | `dot_config/zsh/tools/07_bunx_cli.zsh` | Claude Code usage tracker via `bunx ccusage` |

---

## Task Queue

> Requires `pueue` and `jq`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `pqsum` | function | `dot_config/zsh/tools/36_pueue.zsh` | Summarize pueue queue status: overall progress, ETA, per-group breakdown |

---

## Networking

> Conditional aliases — only defined when the corresponding tool is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ports` | alias | `dot_config/zsh/tools/50_networking.zsh` | List all listening ports (`lsof -i -P -n \| grep LISTEN`) |
| `myip` | alias | `dot_config/zsh/tools/50_networking.zsh` | Show public IP address |
| `localip` | alias | `dot_config/zsh/tools/50_networking.zsh` | Show local IP address (platform-aware) |
| `pingsweep` | function | `dot_config/zsh/tools/50_networking.zsh` | Ping sweep local `/24` subnet via `nmap -sn` *(requires nmap)* |
| `arpscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | ARP scan local network (`sudo arp-scan -l`) *(requires arp-scan)* |
| `dns` | alias | `dot_config/zsh/tools/50_networking.zsh` | DNS lookup via doggo (DoH/DoT/DoQ) *(requires doggo)* |
| `bw-net` | alias | `dot_config/zsh/tools/50_networking.zsh` | Live bandwidth monitor (`sudo bandwhich`) *(requires bandwhich)* |
| `portscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | Fast port scanner via rustscan *(requires rustscan)* |

---

## Shell Utilities

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `zsh-profile` | alias | `dot_config/zsh/10_aliases.zsh` | Profile zsh startup time (`ZSH_PROF=1 zsh -i -c exit`) |
| `ghostty-ssh-terminfo` | function | `dot_config/zsh/10_aliases.zsh` | Install `xterm-ghostty` terminfo on a remote host over SSH (unprivileged) |
| `tldrf` | function | `dot_config/zsh/tools/28_tldr.zsh` | `tldr` with language fallback: zh_TW → zh → en *(requires tldr)* |

---

## Package Managers & Runtime

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `load-nvm` | alias | `dot_config/zsh/10_aliases.zsh` | Lazy-load NVM into current session (normally skipped at startup) |
| `bw-update-completion` | alias | `dot_config/zsh/10_aliases.zsh` | Regenerate cached Bitwarden zsh completion file |
