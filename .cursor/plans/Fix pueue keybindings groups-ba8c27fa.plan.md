<!-- ba8c27fa-cf2e-4152-92a1-9d350276bcf0 -->
---
todos:
  - id: "switch-to-alt"
    content: "Change all pueue channel keybindings from ctrl- to alt- in pueue.toml (keybindings section + header comment)"
    status: pending
  - id: "fix-follow-groups"
    content: "Make the follow action detect numeric (task) vs non-numeric (group) and branch accordingly"
    status: pending
  - id: "fix-filter-group-field"
    content: "Update filter_group action to read group from {split:\\t:2} using alt-g (field stays the same, just the keybinding changes)"
    status: pending
  - id: "update-docs"
    content: "Update docs/tools/tv.md pueue channel section to reflect alt- keybindings"
    status: pending
isProject: false
---
# Fix Pueue Channel Keybindings and Groups Enter

## Problem 1: Keybinding conflicts

Every `ctrl-` binding in the pueue channel (except `ctrl-g`) shadows a TV built-in. Two (`ctrl-k`, `ctrl-l`) are also intercepted by tmux's vim-tmux-navigator before reaching TV. Meanwhile, `alt-` keys have zero conflicts in both TV and tmux.

### Proposed keybinding changes

All task management and clipboard actions move to `alt-`:

| Old | New | Action | Reason |
|-----|-----|--------|--------|
| `ctrl-e` | `alt-e` | Edit | Was shadowing `go_to_input_end` (readline Ctrl+E) |
| `ctrl-y` | `alt-y` | Copy raw command | Was shadowing `copy_entry_to_clipboard` |
| `ctrl-a` | `alt-a` | Copy pueue add | Was shadowing `go_to_input_start` (readline Ctrl+A) |
| `ctrl-g` | `alt-g` | Filter group | Keep consistent with other alt- actions |
| `ctrl-p` | `alt-p` | Pause | Was shadowing `select_prev_entry` |
| `ctrl-r` | `alt-r` | Resume | Was shadowing `reload_source` |
| `ctrl-k` | `alt-k` | Kill | tmux intercepts + shadowed `select_prev_entry` |
| `ctrl-t` | `alt-t` | Restart | Was shadowing `toggle_remote_control` |
| `ctrl-x` | `alt-x` | Remove | Was shadowing `toggle_action_picker` |
| `ctrl-l` | `alt-l` | Clean | tmux intercepts + shadowed `toggle_layout` |

This restores all TV built-in navigation (`ctrl-p`/`ctrl-k` for up/down, `ctrl-a`/`ctrl-e` for input cursor, `ctrl-r` for reload, `ctrl-t` for remote control, `ctrl-x` for action picker, `ctrl-l` for layout toggle).

Note: `alt-` keys require the terminal to send Option as Meta. Ghostty has `macos-option-as-alt = left` (already configured in `dot_config/ghostty/config`).

## Problem 2: Enter on groups view does nothing useful

The `follow` action assumes the selected entry is a task ID. On the groups source (cycle 4), `{split:\t:0}` is a group name (non-numeric), so `pueue follow` and `pueue log` both fail silently.

### Fix: numeric check in the follow action

Make the `follow` action detect whether the entry is a task or group:

```sh
id='{split:\t:0}';
if [ "$id" -eq "$id" ] 2>/dev/null; then
  # Numeric -> task: follow or show log
  pueue follow "$id" 2>/dev/null || pueue log "$id" 2>/dev/null;
  echo; echo '[Press Enter to exit]'; read -r _
else
  # Non-numeric -> group name: show group status
  pueue status -g "$id";
  echo; echo '[Press Enter to exit]'; read -r _
fi
```

For the groups view, Enter shows `pueue status -g <name>` (text overview). For the full interactive filtered TV experience, use `alt-g`.

## Files to change

- `dot_config/television/cable/pueue.toml` -- keybindings section + follow action + filter_group template field
- `docs/tools/tv.md` -- update keybinding tables to reflect `alt-` keys
- Header comment in pueue.toml -- update keybinding reference
