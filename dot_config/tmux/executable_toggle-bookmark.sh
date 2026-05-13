#!/usr/bin/env sh
# ~/.config/tmux/toggle-bookmark.sh
# Source: dot_config/tmux/executable_toggle-bookmark.sh (managed by chezmoi)
#
# Toggle @bookmark_status on a tmux window. Invoked by the MouseDown3Status
# right-click menu in dot_config/tmux/keybindings.conf.tmpl.
#
# Usage:
#   toggle-bookmark.sh <window-id> <glyph>
#     If @bookmark_status on <window-id> already equals <glyph>, unset it.
#     Otherwise overwrite it with <glyph>.
#
# Parallels workmux's @workmux_status — independent per-window user-option,
# both render side-by-side in the catppuccin window-text format
# (dot_config/tmux/theme.catppuccin.conf lines 31–32). For CLI access use the
# generic API from dot_config/shell/60_tmux_status.sh:
#   tmux_status_set bookmark '⭐'      # set on current window
#   tmux_status_clear bookmark         # clear on current window
#
# Why this script instead of inlining in display-menu: expressing
# "if current == X then unset else set to X" requires reading the option
# value first, and the quoting around emoji literals inside a nested tmux
# command list (display-menu → { run-shell … } → { set-option … }) is
# fragile. A tiny external script keeps the menu binding readable.

set -eu

win="${1:-}"
glyph="${2:-}"

if [ -z "$win" ] || [ -z "$glyph" ]; then
    printf 'usage: %s <window-id> <glyph>\n' "$0" >&2
    exit 64
fi

current=$(tmux show-options -wv -t "$win" '@bookmark_status' 2>/dev/null || true)

if [ "$current" = "$glyph" ]; then
    tmux set-option -w -t "$win" -u '@bookmark_status' 2>/dev/null || true
    tmux display-message "Bookmark cleared"
else
    tmux set-option -w -t "$win" '@bookmark_status' "$glyph"
    tmux display-message "Bookmark: $glyph"
fi
