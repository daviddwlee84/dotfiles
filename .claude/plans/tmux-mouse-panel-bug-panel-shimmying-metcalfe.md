# Fix: tmux right-click pane menu flashes and disappears near screen bottom

## Context

When right-clicking on a pane in the **upper portion** of the screen, the
pane context menu (`MouseDown3Pane`) appears and stays open as expected.
When right-clicking on a pane in the **lower portion** of the screen, the
menu briefly appears and then disappears within a frame — unusable.

### Root cause

The binding at `dot_config/tmux/keybindings.conf:13-39` invokes
`display-menu -O -T "..." -t = -x M -y M ...` with **23 visible rows**
(17 items + 5 separators + 1 title) plus tmux's borders ≈ **25 rows of
total menu height**.

`-y M` anchors the **top-left** corner of the menu at the mouse cursor
position. When `mouse_y + 25 > client_height`, the menu would extend
past the bottom of the terminal. tmux 3.3+ tries to clamp it upward to
fit, but the clamp interaction with the queued `MouseDown3` /
`MouseUp3` event leaks dismisses the menu before the user can interact
— observed as the "flash and gone" symptom.

This is **distinct** from the silent-suppression failure mode
documented in `pitfalls/tmux-display-menu-silent-fail.md` (which is
"menu never appears at all" because total menu height > terminal
height). Here the menu *can* fit on the terminal as a whole; it just
can't fit *below* the click point.

### Why we cannot use the existing tier-trim pattern

`menu.sh` solves a different problem (terminal too small overall, not
position-relative). Tier-trimming would help only on small terminals,
not on 50-60 row terminals where the user is clicking near the bottom.

### Why we cannot extract to a `run-shell` script

`pitfalls/tmux-submenu-flash-and-bottom-right.md` documents that any
`display-menu` invoked indirectly via `run-shell` from a `MouseDown3*`
binding loses its "opened from a mouse key binding" status, so `-M`
becomes a no-op and trailing mouse events from the parent leak into
the child. The current binding **must** stay inline with `display-menu`
in `keybindings.conf`.

### Why we cannot use `-y S` / `-y C`

`-y S` (status line) or `-y C` (centre of client) would always place
the menu at a fixed location, losing the cursor-following UX that
makes the right-click menu feel native. The user explicitly noted that
when there is enough space, the menu position is correct — so
preserving cursor-following is a goal.

### Intended outcome

Right-clicking anywhere on the pane should open the menu in a stable,
fully-visible position:

- Above the click point (when there's space) — unchanged behaviour.
- **Below the click point (when within ~25 rows of the bottom) — menu
  opens *above* the cursor instead of getting clamped/flashed.**

## Approach

Replace the static `-y M` with a tmux format expression that picks the
anchor row conditionally on `#{mouse_y}` and `#{client_height}`:

```tmux
-y "#{?#{e|>:#{e|+:#{mouse_y},#{T:@menu_height_pane}},#{client_height}},#{e|-:#{mouse_y},#{T:@menu_height_pane}},#{mouse_y}}"
```

Translation:

> If `mouse_y + menu_height > client_height` (menu would overflow
> downward), anchor the menu at `mouse_y - menu_height` (so the
> bottom of the menu lands at the click point and the menu opens
> *upward*). Otherwise anchor at `mouse_y` (default behaviour).

The menu height is stored as a tmux user option `@menu_height_pane`
set near the top of the binding section, with a comment that ties its
value to the visible-row count of the menu so it can be kept in sync
when items are added/removed.

### Why a tmux user option, not a hardcoded literal

The literal `25` would work but rots silently — the next person to
add or remove a menu row will not realise the anchor math depends on
it. A `set -g @menu_height_pane "25"` line directly above the binding
puts the constant near the menu definition with a comment, and lets us
reference it by name from the format string. This mirrors the
"document the soft cap inline" pattern already used for the window-tab
menu's row count comment at `keybindings.conf:44-53`.

### Cursor-outside-menu after upward repositioning

When the menu opens upward, the cursor will be **just below the
menu's bottom edge**. The binding already uses `-O` (Open), so a
mouse-release at that location does NOT dismiss the menu (this is what
`-O` is for). The user moves the mouse up into the menu to interact —
identical UX to right-clicking near the bottom of any modern GUI app.
No change needed to `-O` or any other flag.

## Critical files

- **`dot_config/tmux/keybindings.conf`** (lines 12-39) — the only
  file modified. Add `set -g @menu_height_pane "25"` directly above
  the `MouseDown3Pane` binding (with a comment block explaining how to
  recompute it when items change), then replace `-y M` with the
  conditional format expression above.

## Notes / non-goals

- **Window-tab menu (`MouseDown3Status`, lines 54-73)** uses `-y W`
  (window position on the status line) and is anchored to the status
  bar, not the cursor — it does not exhibit this bug. No change.
- **Session menu (`MouseDown3StatusLeft`, lines 76-86)** uses
  `-y W` for the same reason. No change.
- **`menu.sh` and submenu scripts** — no change. They use `-y P`
  (top of pane) or `-y W` (status), neither of which has this issue.
- We are NOT trimming the pane menu. All 17 items stay; only the
  positioning logic changes.
- We are NOT changing `-x M` — horizontal clamping in tmux 3.3+
  works fine and the menu's width (~40 cols) rarely overflows.

## Verification

After running `chezmoi apply` and reloading tmux config
(`tmux source-file ~/.config/tmux/tmux.conf` or `prefix + R` if
bound):

1. **Upper-screen behaviour (regression check)** — split a window so
   the top pane is large. Right-click in row 5-10 of the pane. The
   menu should appear with its top-left at the cursor, identical to
   current behaviour.

2. **Lower-screen behaviour (the fix)** — in the same large pane,
   right-click in the **bottom 25 rows** (e.g. row 55 of a 60-row
   terminal). The menu should now appear with its **bottom-left at
   the cursor** (i.e. the menu opens upward), and stay open.

3. **Edge case: tall menu vs short terminal** — shrink the terminal
   to 30 rows (smaller than the menu's 25-row height + a few rows
   margin). Right-click anywhere. tmux's clamping will still adjust
   the position; menu should be visible somewhere on screen and stay
   open. (If menu height ≥ terminal height entirely, the documented
   silent-suppression behaviour from
   `pitfalls/tmux-display-menu-silent-fail.md` still applies — that
   is out of scope for this fix.)

4. **Other right-click menus (regression check)** — right-click on a
   window tab in the status bar, and on the session name on the left
   of the status bar. Both should behave identically to before the
   change (they were never affected).

5. **Submenu interactions (regression check)** — from the pane
   right-click menu, trigger items that themselves open prompts /
   `choose-tree` (e.g. "Send pane to window..." → `S`, "Rename
   window"). Confirm the inner UI still appears and is responsive.
