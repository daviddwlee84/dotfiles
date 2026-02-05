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
1. Bootstrap (run_once_before) - installs uv, ansible, mise
2. chezmoi apply - deploys config files + ansible playbooks
3. Ansible (run_onchange_after) - runs on fresh install + when roles change
```

### Auto-run on Ansible Changes

| Script | Behavior |
|--------|----------|
| `run_once_before_00_bootstrap.sh.tmpl` | Installs uv, mise, ansible (once) |
| `run_onchange_after_20_ansible_roles.sh.tmpl` | Runs ansible with all tags |

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
| `homebrew` | macOS Homebrew installation |
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

| Profile | OS | Package Manager |
|---------|-----|-----------------|
| `macos` | macOS | Homebrew |
| `ubuntu_desktop` | Ubuntu Desktop | apt + snap + mise |
| `ubuntu_server` | Ubuntu Server | apt + snap + mise |

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

## Customization

See [docs/ansible.md](docs/ansible.md) for detailed ansible customization guide.
