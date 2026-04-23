#!/usr/bin/env bash
# Sesh picker — invoked from tmux popup menu (`prefix + Space` → "Sesh picker").
#
# Extracted from dot_config/tmux/keybindings.conf because the inline
# `display-menu` row tripped tmux's command parser: the fzf `{2..}` range
# syntax collides with tmux's `{ ... }` command-block delimiters, silently
# dropping the entire `display-menu` binding (no error, menu just doesn't
# open). See pitfalls/tmux-display-menu-silent-parse-failure.md.
#
# Run via:
#   bind-key -T prefix g run-shell '~/.config/tmux/sesh-picker.sh'
# or as a menu row:
#   "Sesh picker" g "run-shell '~/.config/tmux/sesh-picker.sh'"

set -euo pipefail

selected="$(
  sesh list --icons | fzf-tmux -p 80%,70% \
    --no-sort --ansi \
    --border-label ' sesh ' \
    --prompt '⚡  ' \
    --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find' \
    --bind 'tab:down,btab:up' \
    --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
    --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
    --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
    --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
    --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
    --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
    --preview-window 'right:55%' \
    --preview 'sesh preview {}'
)" || exit 0  # user pressed Esc

[ -z "$selected" ] && exit 0
exec sesh connect "$selected"
