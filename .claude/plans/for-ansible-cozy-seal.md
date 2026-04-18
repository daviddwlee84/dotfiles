# Plan: `ansible` TV channel

## Context

This dotfiles repo manages its system setup through ansible playbooks in `dot_ansible/`
(3 playbooks, 18 roles). Today, browsing them or running syntax checks / playbook
commands means typing long paths from memory (e.g.
`ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check ...`).

Several TV channels already exist under `dot_config/television/cable/` (pueue, tools,
lan-devices, ports, kill-process, ssh-config, aliases, channels) that offer fuzzy
search + previews + action keybindings. A channel for ansible would give the user:

- fuzzy-search across playbooks / roles / tags with inline preview
- one-key actions to `ansible-playbook` run, dry-run, syntax-check
- copy-to-clipboard of the full command for pasting into a terminal
- open-in-editor for quick role/task edits

## Recommended approach

Add a single channel file `dot_config/television/cable/ansible.toml` with three
cyclable sources (Ctrl+S):

1. **Playbooks** — `~/.ansible/playbooks/*.yml`
2. **Roles** — directory listing of `~/.ansible/roles/*/`
3. **Tags** — extracted from `playbooks/*.yml` via `grep -hoE 'tags: \[[^]]+\]'`
   (playbooks use flat `tags: [name]` form, see `dot_ansible/playbooks/macos.yml`)

Display format is TSV with leading `kind` column (`playbook` / `role` / `tag`) so
actions can dispatch by type using `{split:\t:0}`.

### Preview

- playbook → `bat --color=always -l yaml ~/.ansible/playbooks/<name>.yml`
- role → `bat` of `~/.ansible/roles/<name>/tasks/main.yml`, with `defaults/main.yml`
  appended if present
- tag → `grep -rn "tags: \[.*<tag>.*\]" ~/.ansible/playbooks/` so user can see
  which playbook(s) use it

### Keybindings (Alt+* to avoid tmux / TV-builtin clashes)

| Key | Action |
|-----|--------|
| Enter | Run: `ansible-playbook <playbook>` (foreground, `mode = "execute"`) |
| Alt+C | Syntax check: `ansible-playbook --syntax-check ...` |
| Alt+D | Dry run: `ansible-playbook --check ...` |
| Alt+T | Run a playbook **filtered by the current tag** (prompts which playbook if source is tag) |
| Alt+E | Open selected file in `$EDITOR` (playbook file, or role's `tasks/main.yml`) |
| Alt+V | Open the role directory in `yazi` (roles source only) |
| Ctrl+Y / Alt+Y | Copy the full `ansible-playbook ...` command to clipboard (reuse the `_clip()` helper pattern from `pueue.toml` for OSC 52 over SSH) |
| Ctrl+F | Cycle preview (main → defaults for roles; file → matching-lines for tags) |
| Ctrl+O | Toggle preview panel |

All commands use `ANSIBLE_CONFIG=$HOME/.ansible/ansible.cfg` and `cd ~/.ansible`
so they match the manual invocation pattern documented in `CLAUDE.md`.
OS-appropriate playbook default: detect via `uname` in a small shell snippet —
tag actions default to `macos.yml` on Darwin, `linux.yml` otherwise.

## Files to modify

- **Create** `dot_config/television/cable/ansible.toml` — the channel (model after
  `dot_config/television/cable/pueue.toml:31-129` for metadata, sources, actions,
  and the `_clip` OSC-52 helper)
- **Update** `docs/tools/tv.md` — add an `### \`ansible\` channel` section
  alongside the existing `tools`, `lan-devices`, `pueue` sections (around
  `docs/tools/tv.md:42-167`)
- **Update** `README.md` — only if the channel belongs in the user-facing config
  file list; otherwise leave README alone since per-channel detail lives in
  `docs/tools/tv.md`

No changes needed to the `channels` meta-channel (`channels.toml`) — it auto-picks
up any new `*.toml` in the cable dir.

## Verification

1. `chezmoi apply` → file lands at `~/.config/television/cable/ansible.toml`
2. `tv list-channels | grep ansible` → channel is registered
3. `tv ansible` → picker opens with playbooks; Ctrl+S cycles to roles then tags
4. Select `macos.yml`, press **Alt+C** → syntax check runs and exits cleanly
5. Select `devtools` role → preview shows `tasks/main.yml`
6. Select a tag (e.g. `neovim`), press **Ctrl+Y** → clipboard contains
   `ansible-playbook -i ... --tags neovim playbooks/<os>.yml`
7. Press **Alt+E** on a role → `$EDITOR` opens the role's `tasks/main.yml`
8. Run `tv channels` and confirm the new entry appears with its description
