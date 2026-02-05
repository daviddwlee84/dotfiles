# Dotfiles Repository

Cross-platform dotfiles management using **chezmoi** for configuration files and **ansible** for system dependencies.

## Maintaining README.md

**IMPORTANT**: When adding or modifying configurations, update `README.md` to reflect changes:

- **New config files**: Add to "What You Get > Config Files" section
- **New ansible roles/tools**: Add to "What You Get > Tools" section
- **New platforms**: Add to "Supported Platforms" table
- **Changed setup steps**: Update "Quick Setup" section

Keep README.md concise and user-focused. Technical details belong in CLAUDE.md or docs/.

## Quick Start

```bash
# Install ansible (if not already installed)
uv tool install ansible-core
ansible-galaxy collection install community.general

# Apply dotfiles
chezmoi apply

# Run ansible manually (from ~/.ansible directory)
cd ~/.ansible && ansible-playbook playbooks/macos.yml
```

## Architecture

```
chezmoi repo/
├── dot_* files               → ~/.* (config files)
├── dot_ansible/              → ~/.ansible/ (ansible playbooks)
├── run_once_before_*.tmpl    → bootstrap (runs once)
└── run_onchange_after_*.tmpl → ansible (runs on changes)
```

Installation Order:
```
1. Bootstrap (run_once_before) - installs Homebrew (macOS/Linux), uv, ansible, mise
2. chezmoi apply - deploys config files + ansible playbooks
3. Ansible (run_onchange_after) - runs on fresh install + when roles change
4. Brew bundle (run_onchange_after) - installs GUI apps if enabled
```

### Auto-run Scripts

| Script | Behavior |
|--------|----------|
| `run_once_before_00_bootstrap.sh.tmpl` | Installs Homebrew (macOS and Linux), uv, mise, ansible |
| `run_onchange_after_20_ansible_roles.sh.tmpl` | Runs ansible with all tags |
| `run_onchange_after_30_brew_bundle.sh.tmpl` | Runs brew bundle (if `installBrewApps` enabled) |

The onchange script includes SHA256 hashes of all role files. It runs:
- **Fresh install**: no previous hash state → triggers run
- **Updates**: any role's `tasks/main.yml` or `defaults/main.yml` changes → triggers run

To force re-run all scripts:
```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

## Chezmoi Commands

```bash
chezmoi diff              # Preview changes
chezmoi apply             # Apply changes
chezmoi apply --dry-run   # Test without applying
chezmoi edit <file>       # Edit source file
chezmoi cd                # Go to source directory
```

## Ansible Usage

Ansible playbooks run automatically via `chezmoi apply` when playbook files change. For manual runs, use `~/.ansible/` directory:

```bash
cd ~/.ansible

# Full setup (macOS)
ansible-playbook playbooks/macos.yml

# Full setup (Linux)
ansible-playbook playbooks/linux.yml

# Specific tags only
ansible-playbook playbooks/macos.yml --tags "neovim,lazyvim_deps"

# Skip tags requiring sudo
ansible-playbook playbooks/linux.yml --skip-tags "sudo"

# Dry run
ansible-playbook playbooks/macos.yml --check
```

### Available Tags

| Tag | Description |
|-----|-------------|
| `base` | git, curl, ripgrep, fd, build tools |
| `homebrew` | macOS Homebrew update (installation done by bootstrap) |
| `zsh` | zsh, oh-my-zsh, plugins (autosuggestions, syntax-highlighting) |
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf, lazygit, tree-sitter-cli, Node.js (via mise) |
| `devtools` | bat, eza, git-delta, tldr, thefuck, zoxide, direnv, yazi, tmux+tpm, zellij, btop, htop |
| `docker` | Docker/container runtime (OrbStack on macOS, Docker Engine on Linux) |
| `nerdfonts` | Hack Nerd Font for terminal emulators |
| `coding_agents` | Claude Code, OpenCode, Cursor CLI, Copilot CLI, Gemini CLI, SpecStory, Happy |
| `security_tools` | pre-commit, gitleaks |
| `python_uv_tools` | Python CLI tools via uv (apprise, mlflow, litellm, sqlit-tui, etc.) |
| `rust_cargo_tools` | Rust CLI tools via cargo (pueue) |
| `ruby_gem_tools` | Ruby CLI tools via gem (try-cli, toolkami) |

## Profiles

| Profile | OS | Tags Included |
|---------|-----|---------------|
| `macos` | macOS | homebrew, base, zsh, neovim, lazyvim_deps, devtools, docker, nerdfonts, security_tools, rust_cargo_tools, ruby_gem_tools |
| `ubuntu_desktop` | Ubuntu | base, zsh, neovim, lazyvim_deps, devtools, docker, nerdfonts, security_tools, rust_cargo_tools, ruby_gem_tools |
| `ubuntu_server` | Ubuntu | base, zsh, neovim, lazyvim_deps, devtools, docker, security_tools, rust_cargo_tools, ruby_gem_tools |

**Tag categories:**
- **Core** (all): base, zsh, neovim, lazyvim_deps, security_tools
- **Desktop** (macos, ubuntu_desktop): nerdfonts
- **macOS only**: homebrew
- **Optional** (via chezmoi config): coding_agents, python_uv_tools

Note: `ubuntu_server` excludes `nerdfonts` (no GUI needed).

## LazyVim Requirements

- Neovim >= 0.11.2
- ripgrep, fd
- Node.js (via mise on Linux, Homebrew on macOS)
- tree-sitter-cli
- lazygit, fzf (via git on Linux, Homebrew on macOS)

## Directory Structure

After `chezmoi apply`:
- Config files in `~/.*`
- Ansible playbooks in `~/.ansible/`

## Development

After modifying ansible playbooks or roles, run syntax check:

```bash
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/base.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
```

## Ansible vs Homebrew

**Primary tool: Ansible** - manages CLI tools and system dependencies cross-platform.

| Tool | Role | When to Use |
|------|------|-------------|
| **Ansible** | CLI tools, system packages | Always (apt/brew formulas) |
| **Brewfile** | macOS GUI apps (casks), App Store | Optional (opt-in) |
| **Linuxbrew** | Linux packages not in apt | Always installed on Linux |

**How they work together:**
- Bootstrap installs Homebrew on both macOS and Linux
- Ansible roles use `community.general.homebrew` for macOS formulas
- Brewfile manages casks (GUI apps) and mas (App Store) separately
- On Linux, Ansible uses apt; Linuxbrew is available for newer packages

## Brewfile (GUI Apps - Opt-in)

GUI applications are managed via Homebrew Brewfile in XDG-compliant location `~/.config/homebrew/`.

**Note**: Brewfile installation is **opt-in** (disabled by default). Enable via `chezmoi init --force` and set `installBrewApps = true`.

### File Structure

```
~/.config/homebrew/
├── Brewfile          # Shared: taps, CLI formulas, mas
├── Brewfile.darwin   # macOS: casks (GUI apps), mas entries
└── Brewfile.linux    # Linux: linuxbrew-specific (minimal)
```

### Usage

```bash
# Edit Brewfiles
chezmoi edit ~/.config/homebrew/Brewfile.darwin

# Apply changes manually
brew bundle --file=~/.config/homebrew/Brewfile
brew bundle --file=~/.config/homebrew/Brewfile.darwin

# Or just run chezmoi apply (triggers run_onchange script)
chezmoi apply

# Check what would be installed
brew bundle check --file=~/.config/homebrew/Brewfile.darwin
```

### Brewfile Categories (darwin)

- **Terminals & Editors**: alacritty, iterm2, warp, cursor, visual-studio-code
- **AI & Coding**: claude, chatgpt, ollama
- **System Utilities**: aerospace, alt-tab, raycast, jordanbaird-ice
- **Communication**: discord, telegram, wechat, tencent-meeting
- **Browsers**: arc, google-chrome, tor-browser
- **Productivity**: obsidian, google-drive, grammarly-desktop
- **Gaming**: steam, minecraft, battle-net (skipped if WORK_MACHINE env var set)
- **Finance**: binance, tradingview
- **Network**: tailscale, openvpn-connect, clash-verge-rev
- **Mac App Store**: LINE, Keynote, Numbers, Pages

### Customizing Brewfile

The Brewfiles are chezmoi templates. Conditional sections:
- Gaming apps: skipped if `WORK_MACHINE` environment variable is set
- Chinese apps (baidunetdisk): only included if `useChineseMirror` is true
- mas apps: requires signing in to App Store.app first

## Customization

See [docs/ansible.md](docs/ansible.md) for detailed ansible customization guide.
