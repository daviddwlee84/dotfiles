#!/usr/bin/env bash
# Session/window management submenu
set -euo pipefail
exec tmux display-menu -T " Session mgmt " -x R -y P \
  "Rename session"     "\$" "command-prompt -I '#S' 'rename-session -- \"%%\"'" \
  "Rename window"      ","  "command-prompt -I '#W' 'rename-window -- \"%%\"'" \
  "" "" "" \
  "New session"        N  "command-prompt -p 'New session:' 'new-session -s \"%%\"'" \
  "Move window to"     m  "command-prompt -p 'Move window to (session[:index]):' 'move-window -t \"%%\"'" \
  "Break pane to"      r  "command-prompt -p 'Break pane to (session[:index]):' 'break-pane -t \"%%\"'" \
  "Link window to"     K  "command-prompt -p 'Link window to (session[:index]):' 'link-window -t \"%%\"'" \
  "" "" "" \
  "Kill pane"          x  "confirm-before -p 'Kill pane? (y/n)' kill-pane" \
  "Kill session"       X  "confirm-before -p 'Kill session #S? (y/n)' kill-session" \
  "Kill all sessions"  Q  "confirm-before -p 'Kill ALL sessions (tmux server)? (y/n)' kill-server"
