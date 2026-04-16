<!-- 3d7b6906-c09b-4a4b-84cc-03d9147229e9 -->
---
todos:
  - id: "fix-getent"
    content: "Replace `ansible.builtin.getent` with cross-platform shell detection in `dot_ansible/roles/zsh/tasks/main.yml`"
    status: pending
  - id: "fix-ansible-cfg"
    content: "Add `export ANSIBLE_CONFIG` to `run_onchange_after_20_ansible_roles.sh.tmpl`"
    status: pending
  - id: "fix-interpreter-warning"
    content: "Add `interpreter_python = auto_silent` to `dot_ansible/ansible.cfg`"
    status: pending
isProject: false
---
# Fix Ansible macOS Failures

## Problem Analysis

Three issues cause failures/warnings when running `chezmoi apply` on macOS:

1. **Fatal**: `ansible.builtin.getent` uses the `getent` binary (Linux/glibc only, absent on macOS)
2. **Warning**: `ansible.cfg` at `~/.ansible/ansible.cfg` is never loaded (not in Ansible's discovery path)
3. **Warning**: Python interpreter auto-discovery emits a noisy warning

## Fix 1: Replace `getent` with cross-platform shell detection

**File**: `dot_ansible/roles/zsh/tasks/main.yml` (lines 49-65)

Replace the `ansible.builtin.getent` task with two platform-specific shell commands:

- **macOS**: `dscl . -read /Users/<user> UserShell | awk '{print $2}'`
- **Linux**: `getent passwd <user> | cut -d: -f7`

Then update the "Change login shell" condition to use the new registered variable instead of `getent_passwd[...]`.

```yaml
- name: Get current login shell (macOS)
  when: ansible_facts["os_family"] == "Darwin"
  ansible.builtin.command:
    cmd: "dscl . -read /Users/{{ ansible_user_id }} UserShell"
  register: current_shell_macos
  changed_when: false
  check_mode: false
  failed_when: false

- name: Get current login shell (Linux)
  when: ansible_facts["os_family"] != "Darwin"
  ansible.builtin.command:
    cmd: "getent passwd {{ ansible_user_id }}"
  register: current_shell_linux
  changed_when: false
  check_mode: false
  failed_when: false

- name: Set current shell fact
  ansible.builtin.set_fact:
    current_login_shell: >-
      {{ (current_shell_macos.stdout | default('')).split()[-1]
         if ansible_facts["os_family"] == "Darwin"
         else (current_shell_linux.stdout | default('')).split(':')[-1] }}

- name: Change login shell to zsh
  become: true
  tags: [sudo]
  ansible.builtin.user:
    name: "{{ ansible_user_id }}"
    shell: "{{ zsh_path.stdout }}"
  when:
    - zsh_path.rc == 0
    - zsh_path.stdout | length > 0
    - not current_login_shell.endswith('/zsh')
```

## Fix 2: Set `ANSIBLE_CONFIG` in run script

**File**: `run_onchange_after_20_ansible_roles.sh.tmpl` (after line 64)

Add `export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"` right after the `ANSIBLE_DIR` definition so the cfg (with `inject_facts_as_vars = False`) is actually loaded.

```bash
ANSIBLE_DIR="$HOME/.ansible"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
```

## Fix 3: Silence Python interpreter warning

**File**: `dot_ansible/ansible.cfg`

Add `interpreter_python = auto_silent` under `[defaults]` to suppress the Python interpreter discovery warning on every run.

```ini
[defaults]
roles_path = ./roles
inventory = ./inventories/localhost.ini
host_key_checking = False
inject_facts_as_vars = False
interpreter_python = auto_silent
```
