#!/usr/bin/env bash
# Layout submenu (invoked from menu.sh)
set -euo pipefail
exec tmux display-menu -T " Layouts " -x R -y P \
  "Even horizontal" 1 "select-layout even-horizontal" \
  "Even vertical"   2 "select-layout even-vertical" \
  "Main horizontal" 3 "select-layout main-horizontal" \
  "Main vertical"   4 "select-layout main-vertical" \
  "Tiled"           5 "select-layout tiled" \
  "Resize 75%"      "+" "resize-pane -x 75%" \
  "" "" "" \
  "Pane left"       h "select-pane -L" \
  "Pane down"       j "select-pane -D" \
  "Pane up"         k "select-pane -U" \
  "Pane right"      l "select-pane -R" \
  "" "" "" \
  "Swap left/up"    "{" "swap-pane -U" \
  "Swap right/down" "}" "swap-pane -D"
