# Dotfiles Repository

Cross-platform dotfiles management using **chezmoi** for configuration files and **ansible** for system dependencies.

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
├── dot_* files      → ~/.* (config files)
├── dot_ansible/     → ~/.ansible/ (ansible playbooks)
└── run_once_*.tmpl  → triggers ansible on first apply
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

Run from `~/.ansible/` directory:

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
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf, lazygit, tree-sitter-cli |

## Profiles

| Profile | OS | Package Manager |
|---------|-----|-----------------|
| `macos` | macOS | Homebrew |
| `ubuntu_desktop` | Ubuntu Desktop | apt + snap |
| `ubuntu_server` | Ubuntu Server | apt + snap |

## LazyVim Requirements

- Neovim >= 0.11.2
- ripgrep, fd
- Node.js (for LSP servers)
- tree-sitter-cli
- lazygit, fzf

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
