#!/usr/bin/env bash
# ~/.config/tmux/responsive.sh
# Dynamically adjust Catppuccin status bar modules based on terminal width.
# Called on startup and via client-resized hook.
#
# Width tiers:
#   >= 120  (wide)   : full modules
#   80-119  (medium) : reduced right side
#   < 80    (narrow) : minimal, for mobile terminals

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
fi
if [ "$width" -ge 80 ]; then
  tmux set -agF status-right "#{E:@catppuccin_status_host}"
fi
tmux set -agF status-right "#{E:@catppuccin_status_date_time}"

# -- Adjust status length limits to match tier --
if [ "$width" -ge 120 ]; then
  tmux set -g status-left-length 60
  tmux set -g status-right-length 120
elif [ "$width" -ge 80 ]; then
  tmux set -g status-left-length 40
  tmux set -g status-right-length 80
else
  tmux set -g status-left-length 25
  tmux set -g status-right-length 40
fi
