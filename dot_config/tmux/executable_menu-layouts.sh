#!/usr/bin/env bash
# Layout submenu.
#
# Invoked from two places with different position semantics:
#   1. Top popup menu (`prefix + Enter` → Layouts...) — keyboard, no mouse
#      event in flight, parent uses `-x R -y P`.
#   2. Right-click window-tab menu (`Layouts...` row) — mouse-driven; the
#      pending mouse-release/move events from the right-click would dismiss
#      a non-`-O` menu instantly ("flash and gone"), and `-x R -y P` from
#      the status bar lands the popup in the bottom-right corner.
#
# Fix: `-O` keeps the menu Open until an item is chosen / Escape pressed,
# and `-x M -y M` anchors at the mouse position so it appears next to the
# clicked tab. Both anchors fall back gracefully when there's no mouse
# event (keyboard invocation places it at last-known mouse / pane center).
set -euo pipefail
exec tmux display-menu -O -T " Layouts " -x M -y M \
  "Even horizontal" 1 "select-layout even-horizontal" \
  "Even vertical"   2 "select-layout even-vertical" \
  "Main horizontal" 3 "select-layout main-horizontal" \
  "Main vertical"   4 "select-layout main-vertical" \
  "Tiled (grid)"    5 "select-layout tiled" \
  "Resize 75%"      "+" "resize-pane -x 75%" \
  "" "" "" \
  "Pane left"       h "select-pane -L" \
  "Pane down"       j "select-pane -D" \
  "Pane up"         k "select-pane -U" \
  "Pane right"      l "select-pane -R" \
  "" "" "" \
  "Swap left/up"    "{" "swap-pane -U" \
  "Swap right/down" "}" "swap-pane -D"
