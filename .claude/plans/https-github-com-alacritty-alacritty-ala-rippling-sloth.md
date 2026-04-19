# Plan: Add Alacritty to ubuntu_desktop profile

## Context

Alacritty terminal emulator config already lives in the repo (`dot_config/alacritty/alacritty.toml`) but there's no ansible role to install it on Linux. On macOS it's handled as an opt-in Brewfile cask. The goal is to make Alacritty always installed on `ubuntu_desktop` (and `macos`) via ansible, matching the existing pattern for cross-platform GUI tools.

**Key research findings:**
- Alacritty provides **no official Linux binaries** on GitHub releases (Windows/macOS only)
- Official Linux install method is `cargo install alacritty`
- snap package is community-maintained with known LD_LIBRARY_PATH issues — avoid
- macOS already handled by Brewfile.darwin (opt-in), adding to ansible makes it always-on
- `rust_cargo_tools` role already sets up Rust via mise; alacritty role will reuse same shims path
- Skip on `armhf` (no GUI, build would be slow on RPi4 32-bit)

---

## Files to Create

### 1. `dot_ansible/roles/alacritty/tasks/main.yml` (NEW)

```yaml
---
# =============================================================================
# Alacritty - GPU-accelerated terminal emulator
# Linux: cargo install (official); macOS: Homebrew cask
# =============================================================================

# --- macOS ---

- name: Install Alacritty via Homebrew cask (macOS)
  when: ansible_facts['os_family'] == 'Darwin'
  community.general.homebrew_cask:
    name: alacritty
    state: present

# --- Linux ---

- name: Skip Alacritty on armhf (no GPU terminal on 32-bit ARM)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture == 'armv7l'
  ansible.builtin.debug:
    msg: "Skipping Alacritty on armhf — GPU terminal not practical on 32-bit ARM"

- name: Install Alacritty build dependencies (Linux, requires sudo)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name:
      - cmake
      - pkg-config
      - libfontconfig1-dev
      - libxcb-xfixes0-dev
      - libxkbcommon-dev
    state: present
    update_cache: false

- name: Check if Alacritty is already installed (Linux)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
  ansible.builtin.command: alacritty --version
  register: alacritty_check
  changed_when: false
  failed_when: false
  environment:
    PATH: "{{ ansible_facts['env']['HOME'] }}/.cargo/bin:{{ ansible_facts['env']['HOME'] }}/.local/bin:{{ ansible_facts['env']['PATH'] }}"

- name: Check for user-installed mise (Linux)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
    - alacritty_check.rc != 0
  ansible.builtin.stat:
    path: "{{ ansible_facts['env']['HOME'] }}/.local/bin/mise"
  register: mise_user_install

- name: Set mise binary path (Linux)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
    - alacritty_check.rc != 0
  ansible.builtin.set_fact:
    mise_bin: "{{ mise_user_install.stat.exists | ternary(ansible_facts['env']['HOME'] + '/.local/bin/mise', '/usr/local/bin/mise') }}"

- name: Install Alacritty via cargo (Linux)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
    - alacritty_check.rc != 0
  ansible.builtin.command: cargo install alacritty
  args:
    creates: "{{ ansible_facts['env']['HOME'] }}/.cargo/bin/alacritty"
  environment:
    PATH: "{{ ansible_facts['env']['HOME'] }}/.local/share/mise/shims:{{ ansible_facts['env']['HOME'] }}/.cargo/bin:{{ ansible_facts['env']['HOME'] }}/.local/bin:{{ ansible_facts['env']['PATH'] }}"
  timeout: 1200  # cargo build can take 15-20 min on first run

- name: Create ~/.local/share/applications directory (Linux)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
  ansible.builtin.file:
    path: "{{ ansible_facts['env']['HOME'] }}/.local/share/applications"
    state: directory
    mode: '0755'

- name: Install Alacritty desktop entry (Linux)
  when:
    - ansible_facts['os_family'] == 'Debian'
    - target_architecture != 'armv7l'
  ansible.builtin.copy:
    dest: "{{ ansible_facts['env']['HOME'] }}/.local/share/applications/alacritty.desktop"
    mode: '0644'
    content: |
      [Desktop Entry]
      Type=Application
      TryExec=alacritty
      Exec=alacritty
      Icon=alacritty
      Terminal=false
      Categories=System;TerminalEmulator;
      Name=Alacritty
      GenericName=Terminal
      Comment=A fast, cross-platform, OpenGL terminal emulator
      StartupWMClass=alacritty
```

### 2. `dot_ansible/roles/alacritty/defaults/main.yml` (NEW)

Minimal, just for documentation:
```yaml
---
# No defaults needed currently; role is always-on when tagged
```

---

## Files to Modify

### 3. `dot_ansible/playbooks/linux.yml`

Add after `ruby_gem_tools` (must come after `rust_cargo_tools` since it needs cargo):
```yaml
    - role: alacritty
      tags: [alacritty]
```

### 4. `dot_ansible/playbooks/macos.yml`

Add after `ruby_gem_tools`:
```yaml
    - role: alacritty
      tags: [alacritty]
```

### 5. `run_onchange_after_20_ansible_roles.sh.tmpl`

**a) Add role hash** (in the `# === Role Hashes ===` section):
```
# alacritty: {{ include "dot_ansible/roles/alacritty/tasks/main.yml" | sha256sum }}
```

**b) Add `alacritty` to ubuntu_desktop TAGS** (line 87):
```
TAGS="base,zsh,starship,neovim,lazyvim_deps,devtools,docker,nerdfonts,security_tools,rust_cargo_tools,ruby_gem_tools,alacritty"
```

**c) Add `alacritty` to macos TAGS** (line 83):
```
TAGS="homebrew,base,zsh,starship,neovim,lazyvim_deps,devtools,docker,nerdfonts,security_tools,rust_cargo_tools,ruby_gem_tools,alacritty"
```

> ubuntu_server TAGS remain unchanged (no GUI terminal on servers)

### 6. `CLAUDE.md`

**a) Add to Available Tags table:**
| `alacritty` | GPU-accelerated terminal emulator (Alacritty) |

**b) Update ubuntu_desktop profile row** to include `alacritty`

**c) Update macOS profile row** to include `alacritty`

### 7. `README.md`

Add Alacritty to "Config Files" or "Tools" section under devtools/terminal tools, noting it's installed via ansible on both macOS and Linux.

---

## Ordering Note

`alacritty` role must be listed **after** `rust_cargo_tools` in both playbooks because the Linux install path uses `cargo` from the mise-managed Rust toolchain (installed by `rust_cargo_tools`).

---

## Verification

```bash
# Syntax check
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml

# Dry run (Linux, alacritty tag only)
cd ~/.ansible && ansible-playbook playbooks/linux.yml --tags alacritty --check --ask-become-pass

# Full apply
chezmoi apply

# Verify install
alacritty --version
ls ~/.local/share/applications/alacritty.desktop
```
