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
  "Renumber windows"   R  "run-shell 'tmux move-window -r && tmux display-message \"Windows renumbered\"'" \
  "" "" "" \
  "Join marked here (h)" j "join-pane -h" \
  "Join marked here (v)" J "join-pane -v" \
  "Send pane to..."    s  "choose-tree -Zw -F '#{window_name}' \"join-pane -h -s '#{pane_id}' -t '%%' ; display-message 'Sent pane to target'\"" \
  "" "" "" \
  "Kill pane"          x  "confirm-before -p 'Kill pane? (y/n)' kill-pane" \
  "Kill window"        W  "confirm-before -p 'Kill window #W? (y/n)' kill-window" \
  "Kill session"       X  "confirm-before -p 'Kill session #S? (y/n)' kill-session" \
  "Kill session & exit" E  "confirm-before -p 'Kill session #S and exit tmux? (y/n)' \"run-shell '$HOME/.config/tmux/kill-session-exit.sh'\"" \
  "Kill all sessions"  Q  "confirm-before -p 'Kill ALL sessions (tmux server)? (y/n)' kill-server"
