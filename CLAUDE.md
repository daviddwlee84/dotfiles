# Dotfiles Repository

Cross-platform dotfiles management using **chezmoi** for configuration files and **ansible** for system dependencies.

## Quick Start

```bash
# Apply dotfiles
chezmoi apply

# Run ansible manually (after chezmoi deploys ~/.ansible)
ansible-playbook -i ~/.ansible/inventories/localhost.ini ~/.ansible/playbooks/macos.yml
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

```bash
# Full setup
ansible-playbook -i ~/.ansible/inventories/localhost.ini ~/.ansible/playbooks/macos.yml

# Specific tags only
ansible-playbook ... --tags "neovim,lazyvim_deps"

# Skip tags requiring sudo
ansible-playbook ... --skip-tags "sudo"

# Dry run
ansible-playbook ... --check
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

## Customization

See [docs/ansible.md](docs/ansible.md) for detailed ansible customization guide.
