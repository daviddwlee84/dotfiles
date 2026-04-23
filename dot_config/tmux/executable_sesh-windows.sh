#!/usr/bin/env bash
# Sesh windows picker (extracted from inline menu — same nested-quote
# problem as sesh-picker.sh).
set -euo pipefail

selected="$(
  sesh window | fzf-tmux -p 60%,50% \
    --no-sort \
    --border-label ' sesh windows ' \
    --prompt '  '
)" || exit 0

[ -z "$selected" ] && exit 0
exec sesh window "$selected"
