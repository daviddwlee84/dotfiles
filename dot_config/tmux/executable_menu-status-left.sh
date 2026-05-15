#!/usr/bin/env bash
# Status-left (session) right-click menu, invocable from the keyboard via
# `prefix + M-s`. Mirrors the inline body of `MouseDown3StatusLeft` in
# keybindings.conf.tmpl.
#
# WHY a separate copy: see header of executable_menu-pane.sh.
#
# *** IF YOU EDIT THE MENU ITEMS, ALSO UPDATE ***
#     dot_config/tmux/keybindings.conf.tmpl :: MouseDown3StatusLeft
#
# NOTE — "Kill all sessions" routes through executable_kill-server-clean.sh
# to clear tmux-resurrect's `last` symlink before killing the server, so
# tmux-continuum does NOT auto-restore the just-closed sessions on the next
# tmux start. The kept-in-sync inline copy in keybindings.conf.tmpl does the
# same. "Kill session & exit" goes through executable_kill-session-exit.sh,
# which conditionally calls resurrect-forget when it kills the LAST session.
# See pitfalls/tmux-continuum-restores-on-intentional-quit.md.
set -euo pipefail

declare -a rows=(
  "Next"      n "switch-client -n"
  "Previous"  p "switch-client -p"
  "" "" ""
  "Choose session..." c "choose-tree -Zs"
  "Rename"            N "command-prompt -I '#S' \"rename-session '%%'\""
  "" "" ""
  "Move current window to..." m "choose-tree -Zs -F '#{session_name}' \"move-window -s '#{window_id}' -t '%%'\""
  "" "" ""
  "New session" s "new-session"
  "New window"  w "new-window"
  "" "" ""
  "Kill session"        X "kill-session"
  "Kill session & exit" E "run-shell '$HOME/.config/tmux/kill-session-exit.sh'"
  "Kill all sessions"   Q "confirm-before -p 'Kill ALL sessions (tmux server)? (y/n)' \"run-shell '$HOME/.config/tmux/kill-server-clean.sh'\""
)

exec tmux display-menu -T "#[align=centre]#{session_name}" -x R -y P "${rows[@]}"
