#!/usr/bin/env bash
# Detach all clients of the current tmux session, then destroy the session.
# Gives "kill current session and return to parent shell" behavior even
# when `detach-on-destroy off` is set globally (common.conf), which would
# otherwise make `kill-session` switch to another session instead.
set -euo pipefail

session=$(tmux display-message -p '#S')
tmux detach-client -s "$session"
tmux kill-session -t "$session"
