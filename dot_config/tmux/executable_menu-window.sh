#!/usr/bin/env bash
# Window-tab right-click menu, invocable from the keyboard via `prefix + M-w`.
# Mirrors the inline body of `MouseDown3Status` in keybindings.conf.tmpl.
#
# WHY a separate copy: see header of executable_menu-pane.sh.
#
# *** IF YOU EDIT THE MENU ITEMS, ALSO UPDATE ***
#     dot_config/tmux/keybindings.conf.tmpl :: MouseDown3Status
#
# WARNING — height: this menu is 23 visible rows. `display-menu` silently
# suppresses itself if it can't fit on screen. On terminals ≲ 26 rows the
# menu will not appear. Mouse-right-click has the same limitation; this
# script just changes the trigger. See pitfalls/tmux-display-menu-silent-fail.md
# for the height-clamping behavior.
set -euo pipefail

declare -a rows=(
  "Swap Left"  l "swap-window -t :-1"
  "Swap Right" r "swap-window -t :+1"
  "" "" ""
  "Even horizontal" 1 "select-layout even-horizontal"
  "Even vertical"   2 "select-layout even-vertical"
  "Main horizontal" 3 "select-layout main-horizontal"
  "Main vertical"   4 "select-layout main-vertical"
  "Tiled (grid)"    5 "select-layout tiled"
  "" "" ""
  "Move to session..." m "choose-tree -Zs -F '#{session_name}' \"move-window -s '#{window_id}' -t '%%'\""
  "Link to session..." K "choose-tree -Zs -F '#{session_name}' \"link-window -s '#{window_id}' -t '%%:'\""
  "Break all panes → windows" E "run-shell '$HOME/.config/tmux/break-all-panes.sh'"
  "" "" ""
  "Kill window" X "kill-window"
  "Renumber windows" N "run-shell 'tmux move-window -r && tmux display-message \"Windows renumbered\"'"
  "Rename"      n "command-prompt -F -I '#W' \"rename-window -t '#{window_id}' '%%'\""
  "" "" ""
  "⭐ Star"     s "run-shell '$HOME/.config/tmux/toggle-bookmark.sh \"#{window_id}\" \"⭐\"'"
  "📌 Pin"      p "run-shell '$HOME/.config/tmux/toggle-bookmark.sh \"#{window_id}\" \"📌\"'"
  "🔖 Bookmark" b "run-shell '$HOME/.config/tmux/toggle-bookmark.sh \"#{window_id}\" \"🔖\"'"
  "🚩 Flag"     f "run-shell '$HOME/.config/tmux/toggle-bookmark.sh \"#{window_id}\" \"🚩\"'"
  "Clear agent status" c "set-option -w -t '#{window_id}' -u '@workmux_status' ; display-message 'Cleared @workmux_status on #{window_index}:#{window_name}'"
  "" "" ""
  "New window"  w "new-window"
)

exec tmux display-menu -T "#[align=centre]#{window_index}:#{window_name}" -x R -y P "${rows[@]}"
