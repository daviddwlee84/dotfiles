#!/usr/bin/env bash
# ~/.config/tmux/responsive.sh
# Dynamically adjust Catppuccin status bar modules based on terminal width.
# Called on startup and via client-resized hook.
#
# Width tiers:
#   >= 120  (wide)   : full modules incl. clock
#   80-119  (medium) : host only on right (clock dropped to save space)
#   < 80    (narrow) : minimal, no right side, for mobile terminals

set -euo pipefail

# Get the width of the widest attached client (status bar renders for widest)
width=$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 120)

# -- Status Left --
tmux set -g status-left ""
tmux set -agF status-left "#{E:@catppuccin_status_session}"
if [ "$width" -ge 80 ]; then
  tmux set -agF status-left "#{E:@catppuccin_status_directory}"
fi

# -- Status Right --
tmux set -g status-right ""
if [ "$width" -ge 120 ]; then
  tmux set -agF status-right "#{E:@catppuccin_status_application}"
  tmux set -agF status-right "#{E:@catppuccin_status_user}"
  tmux set -agF status-right "#{E:@catppuccin_status_host}"
  tmux set -agF status-right "#{E:@catppuccin_status_date_time}"
elif [ "$width" -ge 80 ]; then
  tmux set -agF status-right "#{E:@catppuccin_status_host}"
fi
# narrow (<80): no right-side modules -- leave full width for the window list

# -- Adjust status length limits to match tier --
if [ "$width" -ge 120 ]; then
  tmux set -g status-left-length 60
  tmux set -g status-right-length 120
elif [ "$width" -ge 80 ]; then
  tmux set -g status-left-length 40
  tmux set -g status-right-length 80
else
  tmux set -g status-left-length 25
  tmux set -g status-right-length 0
fi
