#!/usr/bin/env bash
# Sesh extras submenu
set -euo pipefail
exec tmux display-menu -T " Sesh extras " -x R -y P \
  "TV picker"      V "display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' Sesh (tv) ' 'tv sesh'" \
  "Built-in"       O "display-popup -h 90% -w 50% -E 'sesh picker -i'" \
  "Windows"        W "run-shell '~/.config/tmux/sesh-windows.sh'" \
  "Last sesh"      U "run-shell 'sesh last'" \
  "Repo root"      9 "run-shell 'sesh connect --root \$(pwd)'" \
  "" "" "" \
  "CLI Tools (tv)" B "display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' CLI Tools (tv) ' 'tv tools'"
