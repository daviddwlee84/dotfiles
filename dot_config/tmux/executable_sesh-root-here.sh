#!/usr/bin/env bash
# sesh-root-here — open a lightweight sesh session at the git root of $1
# (typically tmux's #{pane_current_path}). Unlike scode-here.sh this is a
# plain shell at the repo root, no nvim/agent layout — the symmetric
# lightweight counterpart to prefix+9 (scode-here.sh).
#
# Bound to `prefix + 0` and `Ctrl + 0` in keybindings.conf. The previous
# `sesh connect --root $(pwd)` inline binding was broken two ways:
#   1. $(pwd) was expanded once at tmux config parse time (not per-press),
#      so it always pointed at tmux's startup dir.
#   2. `--root` is a boolean flag in sesh (switches to root of CURRENT
#      session), not "set root dir for new session". The path was being
#      treated as a session NAME, which silently created/connected to a
#      session named after the path. Probably not what anyone wanted.
#
# This script does what was actually meant: walk up to find .git, then
# `sesh connect <repo-root>`.

set -eu

target_dir="${1:-$PWD}"

# Walk up to find git root; fall back to target_dir if not in a repo.
repo_root="$(cd "$target_dir" && git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root:-}" ]]; then
    repo_root="$target_dir"
fi

# `sesh connect <name>` either attaches/switches to existing session or
# creates a new one. Idempotent.
if ! sesh connect "$repo_root" 2>/tmp/tmux-sesh-root-here.log; then
    err="$(tail -n 1 /tmp/tmux-sesh-root-here.log 2>/dev/null || echo unknown)"
    tmux display-message "sesh connect failed: $err"
    exit 1
fi
