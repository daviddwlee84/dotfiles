# Plan: Fix locale ansible task — generate only, no system default override

## Context

`dot_config/zsh/00_exports.zsh.tmpl:16-17` sets `LANG` and `LC_ALL` to `en_US.UTF-8` for all machines. On machines where this locale hasn't been generated (e.g. Raspberry Pi with default zh_TW.UTF-8), bash/perl warn at shell startup:

```
/bin/bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)
```

An ansible task was added to fix this, but it has two parts with different blast radii:
1. `locale_gen` — just generates/installs the locale binary → **safe, needed**
2. `update-locale` — overwrites `/etc/default/locale` system-wide → **not needed, intrusive**

The `update-locale` part would override the machine's default locale (e.g., replace `zh_TW.UTF-8` with `en_US.UTF-8` for all users and system services). This is unnecessary because the zsh config already sets LC_ALL per-user session — the system default doesn't need to change.

## What changes

**File:** `dot_ansible/roles/base/tasks/main.yml`

Remove the `update-locale` task (lines 229–234). Keep only the `locale_gen` task.

**Before (current state):**
```yaml
# --- locale ---
- name: Generate en_US.UTF-8 locale (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  community.general.locale_gen:
    name: en_US.UTF-8
    state: present

- name: Set system locale (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  ansible.builtin.command: update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  changed_when: false
```

**After:**
```yaml
# --- locale ---
- name: Generate en_US.UTF-8 locale (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  community.general.locale_gen:
    name: en_US.UTF-8
    state: present
```

## Impact

| | Before fix | After fix |
|---|---|---|
| en_US.UTF-8 available | No → warning | Yes → no warning |
| System default locale | unchanged | unchanged |
| zh_TW prompts/system | unaffected | unaffected |
| Other users | unaffected | unaffected |

The `locale_gen` module writes to `/etc/locale.gen` and compiles locale binaries to `/usr/lib/locale/`. It does **not** touch `/etc/default/locale`. Each machine keeps its own system default.

## Verification

After `chezmoi apply` on rpi:
1. `locale -a | grep en_US` → should show `en_US.utf8`
2. `cat /etc/default/locale` → should still show the original zh_TW setting
3. Open a new shell session → no locale warning
