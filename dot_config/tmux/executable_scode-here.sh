#!/usr/bin/env zsh
# scode-here — open the repo-aware coding-agent layout (`scode`) for the
# directory passed as $1 (typically tmux's #{pane_current_path}).
#
# Bound to `prefix + 9` in dot_config/tmux/keybindings.conf. Lives in its
# own file because:
#   1. tmux run-shell uses /bin/sh and can't see zsh functions/aliases. We
#      need an explicit zsh subshell that sources the helper.
#   2. The session-name + switch-client logic is non-trivial enough that
#      inlining it in keybindings.conf risks the same kind of quoting trap
#      as the display-menu case (see pitfalls/tmux-display-menu-silent-fail).
#   3. Easier to debug — `tmux display-message` errors come back via
#      $TMUX_LOG below.
#
# scode itself walks up to find .git via `git rev-parse --show-toplevel`,
# so any directory inside a repo works. Outside any repo, scode errors and
# we surface that to the tmux status line.
#
# scode is idempotent: calling it again from inside the same repo just
# switches to the existing `coding-agent/<repo>` session.

set -eu

target_dir="${1:-$PWD}"
log="${TMPDIR:-/tmp}/tmux-scode-here.log"

# Source the helper. ZDOTDIR is respected by chezmoi-managed zsh setup.
HELPER="${ZDOTDIR:-$HOME/.config/zsh}/tools/22_sesh.zsh"
if [[ ! -r "$HELPER" ]]; then
    tmux display-message "scode-here: helper not found at $HELPER"
    exit 1
fi

# shellcheck disable=SC1090
source "$HELPER"

# Build the session in the background; sesh-code prints diagnostics on
# stderr if something fails (not a repo, missing tools, etc).
if ! sesh-code --no-attach -p "$target_dir" >"$log" 2>&1; then
    err="$(tail -n 1 "$log" 2>/dev/null || echo "(see $log)")"
    tmux display-message "scode failed: $err"
    exit 1
fi

# Compute the session name the same way sesh-code does, so we can switch.
# _sesh_sanitize and _sesh_git_root are sourced from the helper above.
repo_root="$(cd "$target_dir" && _sesh_git_root)"
session="coding-agent/$(_sesh_sanitize "$(basename "$repo_root")")"

if ! tmux switch-client -t "$session" 2>>"$log"; then
    tmux display-message "scode created '$session' but switch-client failed (see $log)"
    exit 1
fi
