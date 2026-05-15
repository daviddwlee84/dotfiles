#!/usr/bin/env bash
# Remove tmux-resurrect's "last" symlink so the next tmux server start does NOT
# auto-restore via tmux-continuum (@continuum-restore 'on' in common.conf).
# Periodic save (every 15 min by default) will re-create it after restore.
# Only the symlink is removed — historical snapshots stay, so `prefix + Ctrl-r`
# manual restore still works if you change your mind.
#
# Wired into:
#   - executable_kill-server-clean.sh   (always clears)
#   - executable_kill-session-exit.sh   (clears only when this is the last
#                                        surviving session, i.e. the server
#                                        is about to die)
set -euo pipefail
target="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect/last"
rm -f -- "$target"
