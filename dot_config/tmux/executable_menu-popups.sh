#!/usr/bin/env bash
# Popup launcher submenu
set -euo pipefail
exec tmux display-menu -T " Popups " -x R -y P \
  "Lazygit"           g "display-popup -E -w 90% -h 90% -d '#{pane_current_path}' -T ' lazygit ' 'lazygit'" \
  "Shell"             s "display-popup -E -w 80% -h 80% -d '#{pane_current_path}' -T ' shell '" \
  "Floax scratchpad"  f "run-shell '~/.tmux/plugins/tmux-floax/scripts/floax.sh'"
