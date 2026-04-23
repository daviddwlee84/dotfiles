#!/usr/bin/env bash
# Break every pane in the current tmux window into its own window.
#
# Invoked from the right-click window menu and from `prefix + B`.
# Use case: you've been working on a wide screen with a multi-pane layout and
# want to continue on mobile/SSH where a single pane per window is easier than
# zooming with `prefix + z` repeatedly.
#
# Behaviour:
#   - All panes land in the SAME session as the source window.
#   - Each new window inherits the original pane's command/cwd (break-pane
#     defaults).
#   - The source window is left with whatever pane tmux promotes last; if only
#     one pane remained, the source window is unchanged.
#   - New windows are inserted after the source window, in pane-index order.
#   - Names new windows after the pane's current command for easy navigation.

set -euo pipefail

src_window_id=$(tmux display-message -p '#{window_id}')
src_session=$(tmux display-message -p '#{session_name}')
src_index=$(tmux display-message -p '#{window_index}')

# Snapshot pane IDs first — break-pane mutates the list as we iterate.
mapfile -t pane_ids < <(
  tmux list-panes -t "$src_window_id" -F '#{pane_id}'
)

if (( ${#pane_ids[@]} <= 1 )); then
  tmux display-message "break-all-panes: only one pane, nothing to break"
  exit 0
fi

# Leave the first pane in place so the source window doesn't disappear.
# `break-pane -d` keeps focus on the source window.
insert_after=$src_index
for pane_id in "${pane_ids[@]:1}"; do
  insert_after=$((insert_after + 1))
  pane_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}')
  tmux break-pane -d \
    -s "$pane_id" \
    -t "${src_session}:${insert_after}" \
    -n "$pane_cmd" || true
done

tmux display-message "break-all-panes: ${#pane_ids[@]} panes → windows"
