# Plan: Add `gh-notify` as a managed gh extension

## Context

The user wants the GitHub notifications inbox TUI (`meiji163/gh-notify`) installed on this machine and managed by the dotfiles the same way `dlvhdr/gh-dash` already is. Currently `gh dash` is installed via ansible (install-only) and upgraded via `just upgrade-plugins` (`gh extension upgrade --all`). `gh-notify` should join that managed set so it (a) installs on `chezmoi apply` on any authenticated host and (b) is auto-covered by the existing generic upgrade path.

This respects the repo's **install-vs-upgrade split** invariant: ansible installs (guarded, never re-runs); upgrades stay explicit via `just upgrade-*`. The upgrade side needs **no change** — `gh extension upgrade --all` already covers every installed extension.

Correct upstream repo: **`meiji163/gh-notify`** (the earlier web search's `sideshowbarker` attribution was wrong).

## Changes

### 1. Ansible install task — `dot_ansible/roles/devtools/tasks/main.yml`
The gh-dash block (lines ~1188–1222) already registers `gh_cli_path`, `gh_auth_status`, and `gh_extension_list` via three generic probe tasks. **Reuse those registers** — add only ONE new install task after the existing "Install gh-dash extension" task, mirroring it exactly:

```yaml
- name: Install gh-notify extension
  when: gh_cli_path.rc == 0 and gh_auth_status.rc == 0 and (gh_extension_list.rc != 0 or 'meiji163/gh-notify' not in gh_extension_list.stdout)
  ansible.builtin.command: gh extension install meiji163/gh-notify
  changed_when: true
  environment:
    PATH: "{{ ansible_facts['env']['HOME'] }}/.local/bin:/opt/homebrew/bin:/usr/local/bin:{{ ansible_facts['env']['PATH'] }}"
```

Cross-platform (not OS-gated), matching the gh-dash install task. No new probe/auth/list tasks.

### 2. `# Tools:` header — same file, line 3
Add `gh-notify` to the comma-separated list (next to `gh-dash`).

### 3. Docs catalog parity (per CLAUDE.md cross-file rule for tool-managers.md)
`docs/this_repo/tool-managers.md` — add a `gh-notify` row in two tables, mirroring gh-dash:
- **Line ~305** "Linux mechanism" table: `| `gh-notify` | `gh extension install meiji163/gh-notify` |`
- **Line ~997** "Tool index (A–Z)": `| **gh-notify** | `gh extension install meiji163/gh-notify` | same | devtools |` (place right after the `gh-dash` row, before `git`)

Mirror the same two rows into the bilingual twin **`docs/this_repo/tool-managers.zh-TW.md`** for parity.

### No change needed
- `docs/this_repo/upgrades.md` (line 59) and `scripts/upgrade_tools.sh` (lines 870–873) — both use `gh extension upgrade --all`, generic, already covers gh-notify.
- No alias/shell/completion/tv-channel/SKILL.md surface — gh-dash has none, so nothing to mirror. `gh notify` is invoked as the bare extension command.
- No config file — keeping minimal per the request (gh-notify runs fine with defaults; a `dot_config/gh-notify/` can be added later if desired).

## Immediate install (this host)
Since ansible is install-only and the user wants it now, run the one-off directly (does not wait for a full `chezmoi apply`):
```bash
gh extension install meiji163/gh-notify
```

## Verification
1. `gh extension list` → shows `meiji163/gh-notify`.
2. `gh notify` launches the interactive notifications TUI (or prints "no notifications"). `gh notify -h` shows help.
3. Ansible idempotency: re-running the devtools role's gh block reports the new install task as `ok`/skipped (guard matches installed extension).
4. `gh extension upgrade --all` (or `just upgrade-plugins`) includes gh-notify with no error.
5. Grep parity check: `grep -rn "gh-notify" dot_ansible/ docs/this_repo/tool-managers*.md` shows all mirrored surfaces present.
