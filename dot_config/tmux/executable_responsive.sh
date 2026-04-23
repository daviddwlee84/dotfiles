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
#
# IMPORTANT: use `set -gq` (NOT `-gqF`) to store the module references as
# *unexpanded* strings. The status-left/status-right format below then wraps
# the lookup in a single `#{E:...}` expansion.
#
# session is hand-rolled instead of using `#{E:@catppuccin_status_session}`
# because catppuccin's session module stores `#{E:@catppuccin_session_text}`
# (which expands to `#S`) inside its own variable via `set -ag` (not `-agF`).
# This creates triple-nested `#{E:}` expansion that tmux's format cache does
# not invalidate on `client-session-changed`, leaving the old session name
# in status-left after `tmux switch-client` / `sesh connect` until manual
# `prefix + R` reload. See catppuccin/tmux#337.
#
# We replicate the catppuccin look (colour pill + text) using the same
# `@thm_*` palette variables, but with a literal `#S` so tmux re-renders it
# every status refresh.
# session pill changes colour green->red on prefix (built-in client_prefix
# tracking). That colour shift is enough indication; we tried adding a
# separate `⌨ PFX` flag but it duplicated information already conveyed by
# the pill colour change.
_session_block='#[fg=#{?client_prefix,#{E:@thm_red},#{E:@thm_green}}]#{E:@catppuccin_status_left_separator}#[fg=#{E:@thm_crust},bg=#{?client_prefix,#{E:@thm_red},#{E:@thm_green}}] #[fg=#{E:@thm_fg},bg=#{E:@thm_surface_0}] #S#[fg=#{E:@thm_surface_0},bg=default]#{E:@catppuccin_status_right_separator}'

tmux set -gq '@_status_right_wide' \
  '#{E:@catppuccin_status_application}#{E:@catppuccin_status_user}#{E:@catppuccin_status_host}#{E:@catppuccin_status_date_time}'
tmux set -gq '@_status_right_medium' \
  '#{E:@catppuccin_status_host}#{E:@catppuccin_status_date_time}'
tmux set -gq '@_status_right_narrow' ''

tmux set -gq '@_status_left_wide' \
  "${_session_block}#{E:@catppuccin_status_directory}"
tmux set -gq '@_status_left_narrow' \
  "${_session_block}"

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
