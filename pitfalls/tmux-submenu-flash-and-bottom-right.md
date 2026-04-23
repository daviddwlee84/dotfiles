# tmux: submenu opens in bottom-right corner and flashes away when invoked from a right-click menu

**Symptoms** (grep this section): submenu flashes and disappears, popup in bottom-right corner, `display-menu` flickers, right-click submenu won't stay open, tmux menu position wrong from status bar
**First seen**: 2026-04
**Affects**: tmux 3.3+ (likely older too); any `display-menu` submenu invoked from `MouseDown3Status` / `MouseDown3Pane` / `MouseDown3StatusLeft`
**Status**: workaround documented (apply `-O` + `-x M -y M` to dual-purpose submenus)

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

For any submenu that may be opened from a **mouse-driven** parent menu,
combine both:

```sh
exec tmux display-menu -O -T " Layouts " -x M -y M \
  "Even horizontal" 1 "select-layout even-horizontal" \
  ...
```

- `-O` keeps the menu Open until an item is chosen or Escape is pressed —
  immune to the queued mouse-release event from the parent.
- `-x M -y M` anchors at the **mouse position** (last mouse event), so the
  popup appears next to the clicked tab. Falls back gracefully on keyboard
  invocation (last-known mouse position; in practice still readable).

Top-level keyboard-only popups (`menu.sh` triggered by `prefix + Enter`)
can keep `-x R -y P` without `-O` — there's no mouse event to dismiss them
and the cursor-pane anchor is fine for keyboard.

## Why it took a while to spot

- Both quirks are "silent": no error, no log, just wrong position or instant
  dismiss.
- The same submenu script was already used (and working) from
  `prefix + Enter`. Easy to assume "it works, must be the parent menu's
  fault" when right-click triggered it badly.
- Adding `-O` alone fixes the flash but leaves the popup in the bottom-right
  — which then looks like a *new* bug, not the same one.
- Removing `-O` alone after fixing position would re-introduce the flash —
  the two fixes are independent and both required.

## Repository touchpoints

- `dot_config/tmux/executable_menu-layouts.sh` — fixed instance (has docstring
  explaining the dual-invocation contract).
- `dot_config/tmux/keybindings.conf` — `MouseDown3Status` window menu invokes
  it with `run-shell "~/.config/tmux/menu-layouts.sh"`.
- Other submenus (`menu-session.sh`, `menu-system.sh`, `menu-theme.sh`,
  `menu-popups.sh`, `menu-sesh.sh`) are currently only invoked from the
  keyboard popup, so they intentionally still use `-x R -y P` without `-O`.
  If any of these is later wired into a right-click menu, apply the same fix.

## Related

- `pitfalls/tmux-display-menu-silent-fail.md` — different silent failure mode
  for the same `display-menu` command (height clamping / menu-too-tall).
