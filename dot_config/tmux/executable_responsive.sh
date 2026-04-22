#!/usr/bin/env bash
# ~/.config/tmux/responsive.sh
# Build per-client adaptive Catppuccin status bar.
#
# tmux evaluates status-left/status-right ONCE per client per refresh, so
# #{client_width} inside the format expands to *that* client's width. We
# build three module bundles (wide/medium/narrow) into user options, then
# write a status-right whose top-level conditional picks the bundle based
# on the rendering client's width.
#
# Width tiers (per client):
#   >= 120  (wide)   : application + user + host + date_time
#   80-119  (medium) : host + date_time
#   < 80    (narrow) : empty
#
# Called once at startup. No client-resized hook needed -- the format
# itself reacts to each client's width on every status refresh.

set -euo pipefail

# -- Module bundles (stored as user options so the format can reference them)
tmux set -gqF '@_status_right_wide' \
  '#{E:@catppuccin_status_application}#{E:@catppuccin_status_user}#{E:@catppuccin_status_host}#{E:@catppuccin_status_date_time}'
tmux set -gqF '@_status_right_medium' \
  '#{E:@catppuccin_status_host}#{E:@catppuccin_status_date_time}'
tmux set -gq  '@_status_right_narrow' ''

tmux set -gqF '@_status_left_wide' \
  '#{E:@catppuccin_status_session}#{E:@catppuccin_status_directory}'
tmux set -gqF '@_status_left_narrow' \
  '#{E:@catppuccin_status_session}'

# -- Per-client status-right: pick bundle by client_width.
#    e|>=: numeric comparison; nested #{?:,:} is fine here because each
#    branch is a single #{E:@_status_right_*} reference (no commas inside).
tmux set -g status-right \
  '#{?#{e|>=:#{client_width},120},#{E:@_status_right_wide},#{?#{e|>=:#{client_width},80},#{E:@_status_right_medium},#{E:@_status_right_narrow}}}'

tmux set -g status-left \
  '#{?#{e|>=:#{client_width},80},#{E:@_status_left_wide},#{E:@_status_left_narrow}}'

# -- Length limits: take the max we might render, tmux truncates per-client.
tmux set -g status-left-length 60
tmux set -g status-right-length 120
