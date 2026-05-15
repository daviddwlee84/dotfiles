#!/usr/bin/env bash
# Detach all clients of the current tmux session, then destroy the session.
# Gives "kill current session and return to parent shell" behavior even
# when `detach-on-destroy off` is set globally (common.conf), which would
# otherwise make `kill-session` switch to another session instead.
#
# If this is the LAST surviving session (server is about to die), also clear
# tmux-resurrect's "last" symlink so tmux-continuum does NOT auto-restore the
# just-closed session on the next tmux start. When other sessions remain the
# server keeps running and no restore is triggered, so we leave `last` alone.
# See pitfalls/tmux-continuum-restores-on-intentional-quit.md.
set -euo pipefail

session=$(tmux display-message -p '#S')
session_count=$(tmux list-sessions -F '#S' 2>/dev/null | wc -l | tr -d ' ')
if [ "${session_count:-0}" -le 1 ]; then
  "$HOME/.config/tmux/resurrect-forget.sh"
fi
tmux detach-client -s "$session"
tmux kill-session -t "$session"
