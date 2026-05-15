#!/usr/bin/env bash
# Clean tmux quit: forget tmux-resurrect's "last" symlink, then kill the server.
# Goal: stop tmux-continuum's @continuum-restore from re-attaching the just-
# closed sessions on the next tmux start. Used by the "Kill all sessions"
# entries in:
#   - keybindings.conf.tmpl::MouseDown3StatusLeft (status-left right-click menu)
#   - executable_menu-session.sh                  (prefix+Space → Session mgmt)
# Crash recovery is unaffected — historical resurrect snapshots stay on disk
# and `prefix + Ctrl-r` can still restore them manually.
set -euo pipefail
"$HOME/.config/tmux/resurrect-forget.sh"
tmux kill-server
