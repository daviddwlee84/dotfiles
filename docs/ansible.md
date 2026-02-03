# Ansible Customization Guide

This document explains how to customize the ansible setup for your dotfiles.

## Directory Structure

After `chezmoi apply`, ansible files are deployed to `~/.ansible/`:

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

## Prerequisites

Install ansible and required collections:

```bash
# Install ansible with uv
uv tool install ansible-core

# Install community.general collection (for homebrew module)
ansible-galaxy collection install community.general
```

## Running Playbooks

Run from `~/.ansible/` directory (ansible.cfg sets inventory and roles_path automatically):

### Full Setup

```bash
cd ~/.ansible

# macOS
ansible-playbook playbooks/macos.yml

# Linux
ansible-playbook playbooks/linux.yml
```

### Specific Tags

```bash
cd ~/.ansible

# Only install neovim
ansible-playbook playbooks/macos.yml --tags neovim

# Install neovim and its dependencies
ansible-playbook playbooks/macos.yml --tags "neovim,lazyvim_deps"
```

### Skip Tags

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

## Available Tags

| Tag | Description | Requires Sudo |
|-----|-------------|---------------|
| `base` | Essential tools (git, curl, ripgrep, fd, jq) | Linux only |
| `homebrew` | macOS Homebrew installation | No |
| `neovim` | Neovim installation with version check | Linux only |
| `lazyvim_deps` | LazyVim dependencies | Linux only |
| `sudo` | All tasks requiring elevated privileges | Yes |

## Adding New Roles

1. Create role directory structure:

```bash
mkdir -p ~/.ansible/roles/myrole/tasks
mkdir -p ~/.ansible/roles/myrole/defaults  # optional
```

2. Create tasks file `~/.ansible/roles/myrole/tasks/main.yml`:

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

3. Add role to playbook:

```yaml
# In ~/.ansible/playbooks/macos.yml or linux.yml
roles:
  - role: myrole
    tags: [myrole]
```

## Syncing Changes Back to Chezmoi

After experimenting with changes in `~/.ansible/`, add them back to chezmoi:

```bash
# Copy modified files back to chezmoi source
cp ~/.ansible/roles/myrole/tasks/main.yml ~/.local/share/chezmoi/dot_ansible/roles/myrole/tasks/main.yml

# Or use chezmoi re-add
chezmoi re-add ~/.ansible/roles/myrole/tasks/main.yml
```

## OS Detection

Ansible facts used for OS detection:

| Fact | macOS | Ubuntu/Debian |
|------|-------|---------------|
| `ansible_os_family` | Darwin | Debian |
| `ansible_distribution` | MacOSX | Ubuntu |
| `ansible_pkg_mgr` | homebrew | apt |

Example conditional:

```yaml
- name: macOS only task
  when: ansible_os_family == "Darwin"
  # ...

- name: Ubuntu only task
  when: ansible_distribution == "Ubuntu"
  # ...
```

## Sudo Handling

### Linux

Most package installations require sudo. Tasks are tagged with `sudo`:

```yaml
- name: Install package
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name: mypackage
```

Skip these with `--skip-tags sudo` if you don't have sudo access.

### macOS

Homebrew runs as user, no sudo needed. The only exception is system-level changes.

## Troubleshooting

### Syntax Check

```bash
ansible-playbook --syntax-check ~/.ansible/playbooks/base.yml
```

### Verbose Output

```bash
ansible-playbook ... -vvv
```

### List Tasks

```bash
ansible-playbook ... --list-tasks
```

### List Tags

```bash
ansible-playbook ... --list-tags
```

## LazyVim Requirements

LazyVim needs:

- Neovim >= 0.11.2
- ripgrep (for telescope live grep)
- fd (for telescope file finder)
- Node.js (for LSP servers)
- tree-sitter-cli (for syntax highlighting)
- lazygit (optional, for git integration)
- fzf (optional, for fuzzy finding)

All are installed by the `base`, `neovim`, and `lazyvim_deps` roles.
