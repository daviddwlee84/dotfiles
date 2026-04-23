# tmux: nested display-menu via `run-shell` from a right-click parent menu is unreliable

**Symptoms** (grep this section): submenu flashes and disappears, popup in bottom-right corner, `display-menu` flickers, right-click submenu won't stay open, tmux menu position wrong from status bar, submenu opens but selecting an item does nothing on second invocation
**First seen**: 2026-04
**Affects**: tmux 3.3+ (likely older too); any `display-menu` invoked indirectly via `run-shell "$HOME/.config/tmux/menu-foo.sh"` from a `MouseDown3*` parent
**Status**: workaround — inline the submenu items into the parent instead of nesting via shell script

## Symptom

A `tmux display-menu` submenu (e.g. `~/.config/tmux/menu-layouts.sh`) behaves
two different ways depending on how it's invoked:

- From a keyboard popup menu (e.g. `prefix + Enter` → "Layouts..."): opens
  near the cursor / pane center, stays open until an item is chosen. **Works.**
- From a **right-click status-bar** menu (e.g. right-click window tab →
  "Layouts..."): pops up in the **bottom-right corner of the terminal** and
  often **flashes away after a fraction of a second** before any item can be
  picked. Sometimes (if you happen to mouse over a row immediately) it stays.

No error in `tmux show-messages`. The bind is correctly wired — `prefix +
Enter` path proves the script runs.

## Root cause

Two unrelated `display-menu` quirks stacked on top of each other:

### 1. Mouse-release dismiss (the "flash and gone")

A submenu without `-O` closes on the **next mouse event** that isn't a hover.
The right-click on the parent window-tab generated a pending mouse-release /
mouse-move event in tmux's event queue. The parent menu used `-O` (Open)
so it survived; the submenu didn't, so the queued release event hit it
immediately and dismissed it. With keyboard invocation there is no pending
mouse event, so the same submenu stayed open.

### 2. `-x R -y P` from a status-bar event lands at bottom-right

`-x R` = right edge of the pane. `-y P` = the line of the cursor's pane.
When `display-menu` is launched from a `MouseDown3Status` binding, "the
cursor's pane line" resolves to the **status bar row** (very bottom of the
terminal). Combined with `-x R` you get a popup glued to the bottom-right
corner. tmux 3.3+ then clamps it to fit on screen, which makes it look
"stuck" there. From a keyboard popup the cursor is in a normal pane, so the
same `-x R -y P` puts the menu in a sensible place near the parent.

`man tmux` on `display-menu`:
> `M` for the mouse position, `W` for the window position on the status line,
> `S` for the line above or below the status line, `C` for the centre of the
> client.

## Fix

**Don't nest.** Inline the submenu items directly into the parent menu, even
if it pushes the parent above the ~14-row soft cap (see
`AGENTS.md` → "tmux ≥ 3.3 required for popup menu"). The cap exists for a
real reason (small terminals silently suppress oversized menus), so when
inlining grows the parent past 14 rows, drop the lowest-frequency rows and
move them to the keyboard popup (`prefix + Enter` → submenu) where the
nesting works fine.

```tmux
# Bad: nested via run-shell (selection silently no-ops on 2nd invocation)
bind-key -n MouseDown3Status display-menu -O ... \
  "Layouts..." L { run-shell "~/.config/tmux/menu-layouts.sh" } \
  ...

# Good: inline the layout commands directly
bind-key -n MouseDown3Status display-menu -O ... \
  "Even horizontal" 1 { select-layout even-horizontal } \
  "Even vertical"   2 { select-layout even-vertical } \
  "Tiled (grid)"    5 { select-layout tiled } \
  ...
```

The keyboard popup path (`prefix + Enter` → "Layouts..." → `run-shell
~/.config/tmux/menu-layouts.sh`) keeps working — the bug is specific to
mouse-driven parents whose mouse-event lifecycle interferes with the child
menu's input handling.

## Things that look like fixes but aren't

Spent time trying these — none worked reliably across "first invocation"
vs "after cancelling once":

- `-O` on the submenu: stops the immediate flash-and-gone, but on second
  invocation after cancelling the parent, selecting an item silently
  no-ops.
- `-x M -y M` on the submenu: fixes the bottom-right placement, but mouse
  position state is stale after cancel-and-retry, so it pops up in
  unpredictable places.
- `run-shell -d 0.1 "~/.config/tmux/menu-foo.sh"`: deferring the shell
  exec lets the parent's mouse-release drain, fixes the flash, but the
  selection-no-ops bug remains.
- `display-popup` wrapping the submenu: changes mouse semantics entirely
  but you lose `display-menu`'s key shortcuts.

The man page (tmux 3.3+) explains why `-O` alone isn't enough:

> If the mouse is enabled and the menu is opened from a mouse key binding,
> releasing the mouse button … closes the menu. `-M` tells tmux the menu
> should handle mouse events; by default only menus opened from mouse key
> bindings do so.

A submenu launched via `run-shell` is NOT considered "opened from a mouse
key binding" — so `-M` doesn't help either, and the trailing mouse events
from the now-defunct parent leak into an undefined input state for the
child.

## Related

- `pitfalls/tmux-display-menu-silent-fail.md` — different silent failure mode
  for the same `display-menu` command (height clamping / menu-too-tall).
