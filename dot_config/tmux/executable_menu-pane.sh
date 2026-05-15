#!/usr/bin/env bash
# Pane right-click menu, invocable from the keyboard via `prefix + M-p`.
# Mirrors the inline body of `MouseDown3Pane` in keybindings.conf.tmpl.
#
# WHY a separate copy (not extracted from the mouse binding):
#   pitfalls/tmux-submenu-flash-and-bottom-right.md — a `display-menu`
#   launched indirectly via `run-shell` from a `MouseDown3*` binding is
#   not treated as "opened from a mouse key binding" by tmux, so the
#   queued mouse-release event dismisses it (flash-and-gone). Therefore
#   the mouse path MUST stay inline. Keyboard activation has no such
#   queued event, so a script wrapper is safe here.
#
# *** IF YOU EDIT THE MENU ITEMS, ALSO UPDATE ***
#     dot_config/tmux/keybindings.conf.tmpl :: MouseDown3Pane
set -euo pipefail

declare -a rows=(
  "Horizontal Split" h "split-window -h -c '#{pane_current_path}'"
  "Vertical Split"   v "split-window -v -c '#{pane_current_path}'"
  "" "" ""
  "Swap Up"    u "swap-pane -U"
  "Swap Down"  d "swap-pane -D"
  "Swap Left"  l "swap-pane -t '{left-of}'"
  "Swap Right" r "swap-pane -t '{right-of}'"
  "" "" ""
  "#{?window_zoomed_flag,Unzoom,Zoom}" z "resize-pane -Z"
  "Resize 75%"  "+" "resize-pane -x 75%"
  "Resize even" "=" "select-layout even-horizontal"
  "Mark pane"   m "select-pane -m"
  "Swap marked" s "swap-pane"
  "Join marked pane here (h-split)" j "join-pane -h ; display-message 'Joined marked pane here'"
  "Join marked pane here (v-split)" J "join-pane -v ; display-message 'Joined marked pane here'"
  "Send pane to window... (h-split)" S "choose-tree -Zw -F '#{window_name}' \"join-pane -h -s '#{pane_id}' -t '%%' ; display-message 'Sent pane to target'\""
  "Break to new window" B "break-pane ; display-message 'Broke pane out to window #{window_index} (#{window_name})'"
  "" "" ""
  "Enter copy mode" "[" "copy-mode"
  "Respawn"     R "respawn-pane -k"
  "Kill pane"   X "confirm-before -p 'Kill pane? (y/n)' kill-pane"
)

exec tmux display-menu -T "#[align=centre]#{pane_current_command} (pane #{pane_index})" -x R -y P "${rows[@]}"
