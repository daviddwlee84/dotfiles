#!/usr/bin/env bash
# Theme switcher submenu
set -euo pipefail
exec tmux display-menu -T " Theme " -x R -y P \
  "catppuccin (M-c)" c "run-shell 'tmux set -g @theme_variant catppuccin && tmux source-file ~/.tmux.conf && tmux display-message Theme:catppuccin'" \
  "tmux2k (M-t)"     t "run-shell 'tmux set -g @theme_variant tmux2k && tmux source-file ~/.tmux.conf && tmux display-message Theme:tmux2k'"
