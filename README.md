# dotfiles

Cross-platform development environment setup using **chezmoi** + **ansible**.

- **chezmoi**: manages config files (dotfiles)
- **ansible**: installs system dependencies and tools

## Prerequisites

- [chezmoi](https://www.chezmoi.io/install/)
- [uv](https://docs.astral.sh/uv/getting-started/installation/) (for ansible)

## Quick Setup

```bash
# One-liner to initialize and apply
chezmoi init --apply <your-github-username>
```

This automatically:
1. Bootstraps ansible via `uv`
2. Runs base ansible playbook (git, ripgrep, fd, etc.)
3. Runs OS-specific playbook (macOS/Linux)
4. Deploys all config files

## What You Get

### Config Files
- `~/.gitconfig` - Git configuration
- `~/.config/nvim/` - Neovim (LazyVim) configuration
- `~/.config/uv/uv.toml` - uv package manager config
- `~/.claude/` - Claude Code settings

### Tools (via ansible)
- **Base**: git, curl, ripgrep, fd, build tools
- **Neovim**: >= 0.11.2 with LazyVim dependencies
- **LazyVim deps**: fzf, lazygit, tree-sitter-cli

## Supported Platforms

| Platform | Package Manager |
|----------|-----------------|
| macOS | Homebrew |
| Ubuntu Desktop | apt + snap |
| Ubuntu Server | apt + snap |

## Manual Commands

```bash
chezmoi diff          # Preview changes
chezmoi apply         # Apply config files
chezmoi cd            # Go to source directory

# Re-run ansible manually
cd ~/.ansible && ansible-playbook playbooks/macos.yml
```

## Docker Testing

Test the full dotfiles setup on a bare Ubuntu machine:

```bash
# Build and run test suite
just docker-test

# Interactive devbox shell
just docker-run

# Build specific profiles
just docker-desktop    # Ubuntu desktop profile
just docker-china      # China mirror profile
```

## Development with justfile

This project uses [just](https://github.com/casey/just) as a command runner:

```bash
just                  # List all commands
just lint             # Ansible syntax check
just check            # Full lint + dry-run
just docker-build     # Build Docker image
just info             # Show system info
```

## Customization

See [CLAUDE.md](CLAUDE.md) for development guide and [docs/ansible.md](docs/ansible.md) for ansible customization.
