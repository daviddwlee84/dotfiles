# Fix fresh-install failure + smoother post-install UX

## Context

On a fresh Raspberry Pi (Debian, default shell = bash) running:

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply https://github.com/daviddwlee84/dotfiles.git
```

the bootstrap phase completes (Linuxbrew, uv, mise, ansible all install), but `chezmoi apply` then aborts with:

```
chezmoi: 01_backup_dotfiles.sh: exit status 1
```

Downstream effects (all symptoms of the same failure):

- `~/.zshrc`, `~/.bashrc`, `~/.config/*` never deploy.
- `chezmoi` binary lives in `~/.local/bin` but that dir is not on bash's PATH, so `chezmoi status` returns "command not found".
- Login shell is still `bash`; user has to manually figure out how to switch.

Goal: fix the hard failure, and make the post-install experience self-healing (auto-PATH, auto-chsh when possible, clear guidance otherwise).

## Root cause of the hard failure

In `run_before_01_backup_dotfiles.sh.tmpl`, on a machine with nothing pre-existing:

1. No entry in `FILES[]` / `DIRS[]` exists → `BACKED_UP` stays 0.
2. `BACKUP_DIR` is therefore never actually created.
3. Cleanup path runs `rmdir "$BACKUP_DIR" 2>/dev/null` on a non-existent dir.
4. `rmdir` exits 1. Stderr is suppressed, **exit code is not** — and it's the last command.
5. chezmoi aborts apply.

## Plan

### 1. Fix the backup script (the actual bug)

**File:** `run_before_01_backup_dotfiles.sh.tmpl`

- Change `rmdir "$BACKUP_DIR" 2>/dev/null` → `rmdir "$BACKUP_DIR" 2>/dev/null || true`.
- Add explicit `exit 0` at the bottom of the non-template body (before `{{ end -}}`) so the script's final status never depends on whatever happened to run last.

### 2. Auto-add `~/.local/bin` to `~/.bashrc` during bootstrap

**File:** `run_once_before_00_bootstrap.sh.tmpl`

Near the end of the bootstrap (after uv/mise are installed, just before `success "Bootstrap complete!"`), add an idempotent block that ensures bash can find `chezmoi`, `uv`, `mise` even before the user switches to zsh:

```bash
# Ensure ~/.local/bin is on PATH for bash sessions (idempotent)
# This helps users who haven't switched to zsh yet — chezmoi, uv, mise all
# live in ~/.local/bin and need to be reachable from bash.
BASHRC="$HOME/.bashrc"
LOCAL_BIN_LINE='export PATH="$HOME/.local/bin:$PATH"'
if [[ -f "$BASHRC" ]] || [[ "${SHELL##*/}" == "bash" ]]; then
    touch "$BASHRC"
    if ! grep -qF "$LOCAL_BIN_LINE" "$BASHRC"; then
        {
            echo ""
            echo "# Added by chezmoi bootstrap — ~/.local/bin for uv, mise, chezmoi"
            echo "$LOCAL_BIN_LINE"
        } >> "$BASHRC"
        info "Added ~/.local/bin to PATH in $BASHRC"
    fi
fi
```

Rationale: this runs in the bootstrap (before `chezmoi apply`), so even if later steps fail, the user's next bash session can still run `chezmoi`. It only touches `.bashrc` (never `.zshrc` — the dotfiles repo owns that file).

### 3. Auto-`chsh` to zsh when zsh is installed and sudo is available

**File:** `dot_ansible/roles/zsh/tasks/main.yml`

After the existing `Install zsh` tasks, append a task that switches the user's login shell to zsh on Linux/macOS when:

- `zsh` is on PATH (the install step just ensured this),
- the current login shell is not already zsh,
- `noRoot` is not set (chsh writes `/etc/passwd`).

Sketch (Ansible):

```yaml
- name: Determine current login shell
  ansible.builtin.getent:
    database: passwd
    key: "{{ ansible_user_id }}"
  register: passwd_entry
  when: not (no_root | default(false))

- name: Change login shell to zsh
  ansible.builtin.user:
    name: "{{ ansible_user_id }}"
    shell: "{{ zsh_path.stdout }}"
  become: true
  when:
    - not (no_root | default(false))
    - passwd_entry.ansible_facts.getent_passwd[ansible_user_id][5] is defined
    - not passwd_entry.ansible_facts.getent_passwd[ansible_user_id][5].endswith('/zsh')
  vars:
    zsh_path: "{{ lookup('ansible.builtin.pipe', 'command -v zsh') }}"
  tags: [sudo, zsh]
```

Tag with `sudo` so `--skip-tags sudo` / `noRoot=true` mode naturally skips it (consistent with existing convention per CLAUDE.md).

For `noRoot` mode, print a clear notice instead:

```yaml
- name: Notice — manual chsh needed (noRoot)
  ansible.builtin.debug:
    msg: |
      zsh is installed at {{ zsh_path.stdout }} but changing your login shell
      requires sudo. Ask your sysadmin to run:
        sudo chsh -s {{ zsh_path.stdout }} {{ ansible_user_id }}
      Or start zsh manually: exec zsh
  when:
    - no_root | default(false)
```

### 4. README update

**File:** `README.md`

In the "Quick Setup" (or equivalent post-install) section, add a short "After install" subsection:

- Mention that `~/.local/bin` is auto-added to `.bashrc` so tools remain reachable.
- Mention that login shell is auto-switched to zsh on sudo-enabled machines; on `noRoot` or machines where it wasn't switched, tell the user to run `exec zsh` or `chsh -s "$(command -v zsh)"`.
- Mention that users need to open a **new** shell (or `source ~/.bashrc`) after install for PATH changes to take effect.

Keep it to ~5 lines — per CLAUDE.md the README is user-focused and concise.

## Files to modify

- `run_before_01_backup_dotfiles.sh.tmpl` — fix rmdir exit code, add `exit 0`.
- `run_once_before_00_bootstrap.sh.tmpl` — append idempotent `.bashrc` PATH block.
- `dot_ansible/roles/zsh/tasks/main.yml` — add chsh task (gated on `sudo` tag) and a noRoot notice.
- `README.md` — short "After install" note.

## Verification

1. **Unit-test the backup script fix** (on current machine, no harm):
   ```bash
   cd ~/.local/share/chezmoi
   chezmoi execute-template < run_before_01_backup_dotfiles.sh.tmpl | bash
   echo "exit=$?"   # must be 0
   ```

2. **Ansible syntax check** (per CLAUDE.md):
   ```bash
   ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
   ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
   ```

3. **End-to-end on the Pi** (user will do this):
   - Re-run the `curl ... | sh` installer.
   - Expect: bootstrap completes, apply proceeds past backup, dotfiles deploy.
   - New bash session: `chezmoi --version` works (PATH applied).
   - Login shell is zsh after logout/login (or `getent passwd $USER` ends with `/zsh`).
   - On `noRoot=true`: chsh skipped, clear message about `exec zsh` / sysadmin command printed.
