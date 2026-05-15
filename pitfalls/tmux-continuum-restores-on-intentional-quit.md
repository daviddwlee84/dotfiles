# tmux-continuum auto-restores even when you intentionally killed the session

**Symptoms** (grep this section): I closed tmux on purpose but it comes back, tmux restores everything on every start, killed last session and it came back, `tmux kill-server` does nothing useful, sessions reappear after manual quit, continuum auto-restore won't stop, can't get a clean tmux start, tmux-resurrect last symlink keeps respawning sessions
**First seen**: 2026-05
**Affects**: any host using tmux-continuum with `@continuum-restore 'on'` (the repo default in `dot_config/tmux/common.conf.tmpl`)
**Status**: workaround — two clean-quit wrapper scripts (`kill-server-clean.sh`, `kill-session-exit.sh`) clear the `last` symlink before the server dies

## Symptom

You finished your work, ran `tmux kill-server` (or chose "Kill all sessions" from the right-click menu, or killed the last surviving session via `prefix + M-x`), and quit. Next time you start tmux:

```bash
tmux
# (the sessions you just killed come back, every window, every pane)
```

Not a crash recovery. You closed them deliberately. They came back anyway.

## Root cause

`tmux-continuum` and `tmux-resurrect` are designed together:

- `tmux-resurrect` writes periodic snapshots to `~/.local/share/tmux/resurrect/tmux_resurrect_<timestamp>.txt` (every 15 min by default).
- A symlink `~/.local/share/tmux/resurrect/last` always points to the newest snapshot.
- `tmux-continuum` watches the tmux server. When `@continuum-restore 'on'` is set, every time tmux starts with no existing sessions it auto-restores from `last`.

**Continuum cannot tell intent.** "Server gone → restore" — whether the server died because of a crash, a reboot, or because you typed `tmux kill-server` yourself, the outcome is identical: `last` still points to a snapshot that includes the sessions you just killed.

The interval also works against you. If you've been working for an hour, the last snapshot is 0–15 min old, with a full picture of "your work". `kill-server` doesn't invalidate that snapshot — continuum has no on-stop hook.

## Fix

Keep `@continuum-restore 'on'` (it earns its keep on real crashes), but give "I'm intentionally quitting" paths an explicit cleanup that removes the `last` symlink before the server dies. Without `last`, the next tmux start finds nothing to restore from and comes up empty.

Two surfaces matter:

1. **`kill-server`** (the right-click status-left → "Kill all sessions" entry, and the popup-menu's Session → "Kill all sessions" entry) — always intentional, always clean. Wrap in `kill-server-clean.sh`:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   "$HOME/.config/tmux/resurrect-forget.sh"  # rm -f ~/.local/share/tmux/resurrect/last
   tmux kill-server
   ```

2. **`kill-session-exit.sh`** (the `prefix + M-x` binding and right-click status-left → "Kill session & exit" entry) — intentional, but only kills *the current* session. If other sessions remain, the server keeps running and no restore is triggered, so leave `last` alone. If this is the LAST surviving session the server dies; cleanup needed:

   ```bash
   session_count=$(tmux list-sessions -F '#S' 2>/dev/null | wc -l | tr -d ' ')
   if [ "${session_count:-0}" -le 1 ]; then
     "$HOME/.config/tmux/resurrect-forget.sh"
   fi
   tmux detach-client -s "$session"
   tmux kill-session -t "$session"
   ```

`resurrect-forget.sh` only removes the symlink — historical snapshots stay on disk so `prefix + Ctrl-r` (manual restore) still works if you change your mind.

Other kill paths (`prefix + x` kill-pane, `prefix + W` kill-window, plain `prefix + X` kill-session when other sessions remain) DO NOT touch the symlink — they're not "I'm exiting tmux" actions. The server keeps running, no restore is triggered, no cleanup needed.

## Things that look like fixes but aren't

- **`@continuum-restore 'off'`** (or removing the line entirely). Works, but throws out the baby with the bathwater: real crashes / reboots no longer auto-restore either. The whole point of continuum is to survive those. If you genuinely never want auto-restore, this is the right choice — but most users do want crash recovery.
- **`rm -rf ~/.local/share/tmux/resurrect/`** after `kill-server`. Nukes history too — you lose the manual-restore safety net. Symlink-only removal is enough.
- **Setting `@continuum-save-interval 0`** to stop periodic saves. Stops the symlink from advancing, but doesn't clear the existing `last`. Combine with manual deletion and you've effectively disabled continuum — see option 1.
- **A tmux hook on `session-closed`** to clear the symlink. Fires on every session close, including ones where the server is staying up; would also fire when you close a session in a multi-session setup, removing the safety net for the sessions that remain. The session-count check inside `kill-session-exit.sh` is the right level.
- **Touching `~/.local/share/tmux/resurrect/last` to point at /dev/null**. Resurrect reads-and-parses the file content; pointing it at a non-snapshot just makes the restore noisy or fail visibly. Removing the symlink entirely is the documented "do nothing" signal.

## Why not just disable auto-restore?

The user-facing trade-off:

|                          | Auto-restore on | Auto-restore off |
|--------------------------|-----------------|------------------|
| After reboot / crash     | sessions come back automatically ✓ | manual `prefix + Ctrl-r` needed |
| After intentional `kill` | sessions come back unwantedly ✗ → fixed by this workaround | clean exit ✓ |
| Manual restore           | always available  | always available |

The workaround gives you the upper-right cell (clean intentional exit) without losing the upper-left cell (automatic crash recovery). That's why we keep `@continuum-restore 'on'`.

## Related

- [`pitfalls/tmux-resurrect-agents.md`](tmux-resurrect-agents.md) — coding-agent panes restore as bare shells (different problem, same plugin pair).
- [`pitfalls/tmux-submenu-flash-and-bottom-right.md`](tmux-submenu-flash-and-bottom-right.md) — why the keyboard equivalents (`prefix + M-p/w/s`) are scripts while the mouse `MouseDown3*` bindings stay inline.
