#!/usr/bin/env bash
# Tmux popup helper for the "AI session summary" entry in menu-session.sh.
#
# Why a separate script (not inlined in the menu): CLAUDE.md hard rule —
# tmux's display-menu parser treats `{}`, `;`, and `|` as delimiters, and
# the fzf --bind expression below uses all of them. Keeping the pipeline
# in its own file eliminates the parser-quoting trap entirely.
#
# Companion files:
#   - dot_config/tmux/executable_tmux-session-summary.py  (the core)
#   - dot_config/shell/61_tmux_summary.sh                 (the `tsum` shell wrapper; same pipeline for -i)
#   - dot_config/tmux/executable_menu-session.sh          (the calling menu)
set -euo pipefail

# Honour TSUM_TMUX_BIN for the switch-client call too — on machines with
# multiple tmux binaries (apt vs appimage), the script needs to invoke the
# SAME binary that's running the host server, else `switch-client` either
# fails or targets the wrong server.
tmux_bin="${TSUM_TMUX_BIN:-tmux}"

script="$HOME/.config/tmux/tmux-session-summary.py"

if [ ! -x "$script" ]; then
    printf 'AI session summary: %s missing or not executable. Run `chezmoi apply`.\n' "$script" >&2
    sleep 2  # popup auto-closes too fast otherwise
    exit 1
fi
if ! command -v fzf >/dev/null 2>&1; then
    printf 'AI session summary: fzf required for picker mode. (apt/brew install fzf)\n' >&2
    sleep 2
    exit 1
fi

# `|| exit 0` — Esc / Ctrl-C in fzf exits 130; we want the popup to just
# close quietly, not surface a non-zero exit.
selected=$(
    "$script" picker "$@" \
        | fzf --ansi \
              --delimiter=$'\t' \
              --with-nth=2 \
              --preview='printf "%s\n" {2}' \
              --preview-window='down:3:wrap' \
              --prompt='session> ' \
              --header='Enter: switch  /  Esc: cancel' \
              --no-multi
) || exit 0

[ -z "$selected" ] && exit 0

# First TAB-delimited field is the session name.
"$tmux_bin" switch-client -t "${selected%%	*}"
