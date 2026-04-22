# Project Maintenance Cheatsheet

Quick reference for all CLI commands used to maintain this dotfiles repo.

> Most commands have a `just` shortcut. Run `just` (no args) to list every available recipe.

---

## Table of Contents

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

| Command | `just` shortcut | Description |
|---------|-----------------|-------------|
| `chezmoi diff` | `just chezmoi-diff` | Preview what would change |
| `chezmoi apply` | `just chezmoi-apply` | Deploy dotfiles and trigger run scripts |
| `chezmoi apply --dry-run` | `just chezmoi-dry-run` | Test apply without making changes |
| `chezmoi status` | `just chezmoi-status` | Show modified/added/removed files |
| `chezmoi edit <file>` | — | Edit a source file (e.g. `chezmoi edit ~/.zshrc`) |
| `chezmoi cd` | — | Jump to the chezmoi source directory |
| `chezmoi init` | `just chezmoi-reinit` | Re-run interactive init prompts |
| `chezmoi state delete-bucket --bucket=scriptState` | `just chezmoi-clear-scripts` | Reset run_once script state |
| *(clear + apply)* | `just chezmoi-rerun-scripts` | Clear script state then re-apply |

---

## Ansible

Playbooks live in `~/.ansible/` after `chezmoi apply` (source: `dot_ansible/`).

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

**`just` shortcuts:**

```bash
just ansible-syntax-check         # Check all playbooks
just ansible-base                 # Run base playbook
just ansible-macos                # Run macOS playbook
just ansible-linux                # Run Linux playbook
just ansible-tags "neovim,zsh"    # Run specific tags only
just ansible-check                # Dry run (--check)
just ansible-security             # security_tools tag only
```

### Available Ansible Tags

| Tag | Description |
|-----|-------------|
| `base` | git, curl, ripgrep, fd, build tools |
| `zsh` | zsh, oh-my-zsh, plugins |
| `starship` | Starship cross-shell prompt |
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf, lazygit, tree-sitter-cli, Node.js |
| `devtools` | bat, eza, delta, zoxide, tmux, sesh, zellij, btop, television, yazi, … |
| `docker` | Docker / OrbStack |
| `nerdfonts` | Hack Nerd Font |
| `security_tools` | pre-commit, gitleaks |
| `homebrew` | macOS Homebrew update *(macOS only)* |
| `coding_agents` | Claude Code, Cursor CLI, Gemini CLI, etc. *(opt-in)* |
| `bitwarden` | Bitwarden CLI + Desktop *(opt-in)* |
| `python_uv_tools` | uv-managed CLI tools *(opt-in)* |
| `llm_tools` | Ollama, LiteLLM, llmfit *(opt-in)* |
| `rust_cargo_tools` | pueue, etc. via cargo |
| `ruby_gem_tools` | try-cli, tmuxinator via gem |
| `input_method` | McBopomofo + RIME *(desktop + opt-in)* |
| `networking_tools` | nmap, doggo, httpie, bandwhich, rustscan, … *(opt-in)* |

---

## Brew Bundle

GUI apps are opt-in (`installBrewApps = true` during `chezmoi init`).

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

> `chezmoi apply` triggers Brew Bundle automatically when Brewfile content changes.

---

## Docker

Used for testing the full setup on a bare Ubuntu image.

| Command | Description |
|---------|-------------|
| `just docker-build` | Build default image (ubuntu_server) |
| `just docker-build-all` | Build server + desktop + china profiles |
| `just docker-run` | Interactive shell in devbox container |
| `just docker-up` | Start devbox container in background |
| `just docker-down` | Stop all containers |
| `just docker-test` | Run full test suite in container |
| `just docker-desktop` | Build + enter desktop profile |
| `just docker-china` | Build + enter china profile (Chinese mirrors) |
| `just docker-clean` | Remove all dotfiles containers and images |

---

## Pre-commit & Gitleaks

> See [`docs/tools/pre-commit.md`](../tools/pre-commit.md) for the generic pre-commit reference (how its virtualenv-per-hook model works, `uv`-managed bootstrap Python, and troubleshooting broken hook envs).

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
