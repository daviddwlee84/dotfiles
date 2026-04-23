#!/usr/bin/env bash
# Cross-session window/pane operations triggered from prefix + M/B/A pickers.
#
# Source IDs are stashed in tmux global env vars (_src_window / _src_pane) by
# the binding *before* opening choose-tree, because '#{window_id}' inside the
# choose-tree callback expands AFTER selection — at which point the client
# may have switched away from the source.
#
# Why a separate script (not inline in keybindings.conf):
#   - choose-tree's callback is a quoted command string. Nesting both
#     "$_src_window" expansion AND $(tmux display-message …) inside requires
#     juggling 3+ levels of quoting (tmux config string → choose-tree
#     callback string → run-shell single-quoted shell → command substitution).
#     Easier to keep here and call by name.
#
# Args: <op> <picker-target>
#   op: move | break | link
#   picker-target: literal "%%" forwarded by choose-tree, of the form "=session"

set -euo pipefail

op="${1:?op required (move|break|link)}"
raw="${2:?picker target required}"

# Strip choose-tree's leading '=' (raw-target marker) and any trailing :window
sess="${raw#=}"
sess="${sess%%:*}"

src_window="${_src_window:-}"
src_pane="${_src_pane:-}"

describe_window() {
  tmux display-message -p -t "$1" '#S:#I (#W)'
}

case "$op" in
  move)
    [ -n "$src_window" ] || { tmux display-message "no source window"; exit 1; }
    tmux move-window -s "$src_window" -t "${sess}:"
    tmux switch-client -t "$src_window"
    tmux display-message "Moved to $(describe_window "$src_window")"
    ;;
  break)
    [ -n "$src_pane" ] || { tmux display-message "no source pane"; exit 1; }
    tmux break-pane -s "$src_pane" -t "${sess}:"
    tmux switch-client -t "$src_pane"
    tmux display-message "Broken to $(describe_window "$src_pane")"
    ;;
  link)
    [ -n "$src_window" ] || { tmux display-message "no source window"; exit 1; }
    tmux link-window -s "$src_window" -t "${sess}:"
    tmux display-message "Linked into ${sess} (window stays in current session too)"
    ;;
  *)
    tmux display-message "unknown op: $op"
    exit 1
    ;;
esac
