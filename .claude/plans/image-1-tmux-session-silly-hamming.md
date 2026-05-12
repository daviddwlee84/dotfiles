# Tmux status-left right-click menu: add session-level kill + switch items

## Context

`dot_config/tmux/keybindings.conf.tmpl:82-93` defines an inline `display-menu`
bound to `MouseDown3StatusLeft` — right-clicking the session label in the
top-left status bar. The current 6-action menu (Next, Previous, Rename,
Move current window, New session, New window) covers navigation and creation
but not the **kill** and **switch-session** verbs that the user reaches for
most often.

Those same verbs already exist in the keyboard-driven Session mgmt submenu at
`dot_config/tmux/executable_menu-session.sh:5-23` (`prefix + Space → S`),
with hotkeys `X`, `E`, `Q`. Surfacing them on the right-click menu means the
session label becomes a one-click contextual entry point for the same
session lifecycle operations.

User-confirmed scope:

- Add **Kill session (X)**, **Kill session & exit (E)**, **Kill all sessions (Q)**, **Choose session... (c)**
- **No** `confirm-before` wrapper (matches the existing right-click menu's
  zero-prompt style — caller asked for parity with the right-click style, not
  the Session mgmt style)
- Hotkeys aligned with Session mgmt (`X` / `E` / `Q`) so muscle memory
  carries across both menus

## Constraints

- **Menu height ≤ terminal height** is a hard tmux constraint (`man tmux`:
  "If the menu is too large to fit on the terminal, it is not displayed.")
  — silent failure, no error in `tmux show-messages`. See
  [pitfalls/tmux-display-menu-silent-fail.md](../../pitfalls/tmux-display-menu-silent-fail.md).
- The script-generated top menu (`menu.sh`) reads `#{client_height}` and
  tier-trims; an **inline** `display-menu` cannot. So this menu has to fit
  the smallest terminal the user actually right-clicks from.
- CLAUDE.md "Tmux popup menu" caps the top menu at ~14 visible rows. The
  right-click menu is short by default (~11) and we should stay close —
  target ≤ 14 visible rows including title.

Final layout: 10 actions + 4 separators + title bar = **15 rows**. One row
over the soft cap, but the menu is mouse-invoked from a status-bar context
(user is looking at the full status line — terminal is normal-height). The
prior version was 11 rows; we add 4 actions + 1 separator.

## Change set

**File 1**: `dot_config/tmux/keybindings.conf.tmpl` — replace lines 82-93.

```tmux
unbind-key -n MouseDown3StatusLeft
bind-key -n MouseDown3StatusLeft \
  display-menu -O -T "#[align=centre]#{session_name}" -t = -x M -y W \
    Next        n { switch-client -n } \
    Previous    p { switch-client -p } \
    "" \
    "Choose session..." c { choose-tree -Zs } \
    Rename      N { command-prompt -I "#S" { rename-session "%%" } } \
    "" \
    "Move current window to..." m { choose-tree -Zs -F "#{session_name}" "move-window -s '#{window_id}' -t '%%'" } \
    "" \
    "New session" s { new-session } \
    "New window"  w { new-window } \
    "" \
    "Kill session"        X { kill-session } \
    "Kill session & exit" E { run-shell "~/.config/tmux/kill-session-exit.sh" } \
    "Kill all sessions"   Q { kill-server }
```

Notes on the diff:

- **`Choose session... c`** placed after `Next/Previous` separator and before
  `Rename` — it's the "navigate to a session by name" sibling of next/prev,
  so it belongs in the navigation group.
- **`Rename N`** keeps its existing `N` hotkey (mismatched with Session mgmt's
  `$`, but changing it would break existing muscle memory of this menu's users
  and `$` is awkward to type unshifted). Documented mismatch, leave alone.
- **`Kill session X`** reuses the existing `kill-session` command directly,
  no confirm wrapper. Note: per-tmux-config `detach-on-destroy off` means
  this **switches to another session** rather than detaching — that's why a
  separate **`Kill session & exit E`** row invokes the existing
  `~/.config/tmux/kill-session-exit.sh` helper, which detaches all clients
  *then* kills (see header comment in that script).
- **`Kill all sessions Q`** runs `kill-server` directly — destroys the whole
  tmux server, all sessions in it. User explicitly opted in with no confirm;
  this is the price of parity with the rest of the right-click menu's style.

**File 2**: `docs/tools/tmux/keybindings.md:164` — update summary row.

```diff
-| Session area on the left (`MouseDown3StatusLeft`) | Next/prev/rename session, move current window, new session/window |
+| Session area on the left (`MouseDown3StatusLeft`) | Next/prev/choose/rename session, move current window, new session/window, kill session/kill-and-exit/kill-all-sessions |
```

**File 3**: `docs/tools/tmux/keybindings.zh-TW.md:169` — zh-TW mirror.

```diff
-| 左側 session 區 (`MouseDown3StatusLeft`) | Next/prev/rename session、move current window、new session/window |
+| 左側 session 區 (`MouseDown3StatusLeft`) | Next/prev/choose/rename session、move current window、new session/window、kill session/kill-and-exit/kill-all-sessions |
```

## Files NOT touched (and why)

- `dot_config/tmux/executable_menu-session.sh` — the keyboard Session mgmt
  submenu already has these rows with hotkeys `X` / `E` / `Q`. No change.
- `dot_config/tmux/executable_kill-session-exit.sh` — reused as-is for the
  new "Kill session & exit" row.
- `dot_config/tmux/menu.sh` — unrelated (top-level `prefix + Space` menu).
- Cross-file maintenance table in CLAUDE.md doesn't trigger: this is not a
  Ctrl+/Alt+ keybinding, not an alias, not a shell function, not a new
  `docs/` page, not a new `.chezmoi.toml.tmpl` prompt.

## Verification

End-to-end smoke (after `chezmoi apply`, inside a tmux session):

1. `tmux source-file ~/.config/tmux/tmux.conf` — verifies the template renders
   to valid tmux syntax (per CLAUDE.md "Validate app configs with the app,
   not just syntax").
2. Right-click on the session name in the status bar's top-left. Confirm:
   - 4 new rows appear at expected positions (`Choose session...`, `Kill
     session`, `Kill session & exit`, `Kill all sessions`)
   - Hotkeys `c`, `X`, `E`, `Q` activate the right rows
   - Menu fits on terminal — if it gets suppressed, `tmux show-messages` won't
     show an error (the silent-fail pitfall); reproduce by shrinking terminal
     vertically to find the cutoff height
3. Drive each new row:
   - `c` → `choose-tree` picker appears, Enter switches to that session
   - `X` on a multi-session server → current session killed, client switches
     to another session (because `detach-on-destroy off` in common.conf)
   - `E` → all clients of current session detach, session destroyed, return
     to parent shell
   - `Q` → **destructive** — only run when no work pending; verifies
     `kill-server` reachable

If `tmux source-file` rejects the new file, no live tmux session is harmed
(old config stays in memory) — just fix and re-source.

## Risk callout

`Kill session`, `Kill session & exit`, and especially `Kill all sessions`
land in the menu with **no confirmation prompt** per user request. A
mis-click on `Q` destroys every session on the server. This is the price of
parity with the existing right-click menu's no-confirm style; the Session
mgmt submenu (`prefix + Space → S`) still wraps the same actions in
`confirm-before` and remains the safer keyboard path.
