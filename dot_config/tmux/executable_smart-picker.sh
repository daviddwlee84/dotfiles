#!/usr/bin/env bash
# Smart picker — unified entry point for tmux session / project / worktree switching.
#
# Invoked from:
#   - tmux:       bind-key "g" run-shell '~/.config/tmux/smart-picker.sh'
#   - tmux menu:  menu.sh → "Sesh picker" row
#   - zsh ZLE:    sesh-sessions widget (Alt+S), via 22_sesh.zsh
#
# Source filter hotkeys inside the popup (muscle memory inherited from the
# previous sesh-picker.sh — ^w is the new addition):
#   ^a all         sesh list --icons
#   ^t tmux        sesh list -t --icons (active tmux sessions)
#   ^g configs     sesh list -c --icons
#   ^x zoxide      sesh list -z --icons (frecency dirs)
#   ^w worktrees   this script --list-worktrees (current repo's worktrees)
#   ^f find        fd walk from $HOME (depth 2)
#   ^d kill        kill the tmux session under cursor, then reload
#
# Smart dispatch on Enter (Case order matters — first match wins):
#   1. Existing tmux session name   → sesh connect (sesh handles switch/attach)
#   2. Path inside a git repo       → scode -p <path> (coding-agent layout)
#   3. Path NOT inside a git repo   → sesh connect (plain; honors wildcards)
#   4. Configured sesh session name → sesh connect (honors startup_command)
#
# Why call `scode` (zsh function) from bash: the existing scode handles all
# the per-repo session naming + layout + specstory wrapping. Reinventing it
# here would drift. `zsh -ic` sources zshrc → defines the alias → runs it.
#
# ANSI handling: sesh list --icons emits ANSI color codes. fzf --ansi renders
# them correctly, but the returned string still contains them. `sesh connect`
# tolerates ANSI-tainted input (it has for months), but our own path-vs-name
# check below strips ANSI before inspecting.

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
# Resolve to absolute path so fzf's reload(...) subshells find us reliably.
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SCRIPT_ABS="${SCRIPT_DIR}/$(basename "$SCRIPT_PATH")"

# ── Worktree source ────────────────────────────────────────────────────────
# MVP: list worktrees of the current working directory's repo only. `git
# worktree list --porcelain` is stable, doesn't require worktrunk, and matches
# what `wt list` would show for the current project. No output if not in a
# repo — the picker just renders an empty list for ^w in that case.
list_worktrees() {
    git worktree list --porcelain 2>/dev/null |
        awk '/^worktree / { print "🌲 " $2 }'
}

if [[ "${1:-}" == "--list-worktrees" ]]; then
    list_worktrees
    exit 0
fi

# ── Picker ─────────────────────────────────────────────────────────────────
selected="$(
    sesh list --icons | fzf-tmux -p 80%,70% \
        --no-sort --ansi \
        --border-label ' smart ' \
        --prompt '⚡  ' \
        --header '  ^a all ^t tmux ^g configs ^x zoxide ^w worktrees ^f find ^d kill' \
        --bind 'tab:down,btab:up' \
        --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
        --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
        --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
        --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
        --bind "ctrl-w:change-prompt(🌲  )+reload(${SCRIPT_ABS} --list-worktrees)" \
        --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
        --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
        --preview-window 'right:55%' \
        --preview 'sesh preview {}'
)" || exit 0

[[ -z "$selected" ]] && exit 0

# ── Dispatch ───────────────────────────────────────────────────────────────
# Strip ANSI escape codes for inspection. $'\033' is the ESC literal; works
# on both GNU sed (Linux) and BSD sed (macOS).
esc=$'\033'
clean="$(printf '%s' "$selected" | sed "s/${esc}\[[0-9;]*[a-zA-Z]//g")"
# Strip leading whitespace, then the icon column (everything up to first space),
# then any remaining leading whitespace.
clean="${clean#"${clean%%[![:space:]]*}"}"   # trim leading whitespace
payload="${clean#* }"                         # drop icon + one space
payload="${payload#"${payload%%[![:space:]]*}"}"  # trim any residual leading ws

# Case 1: existing tmux session (sesh's -t filter includes these with name-only,
# not path; `tmux has-session` is the cheapest correctness check).
if tmux has-session -t "=$payload" 2>/dev/null; then
    exec sesh connect "$selected"
fi

# Case 2: payload is a path → expand ~ and smart-detect git vs non-git
case "$payload" in
    "~"*) target="${HOME}${payload#\~}" ;;
    /*)   target="$payload" ;;
    *)    target="" ;;
esac

if [[ -n "$target" && -d "$target" ]]; then
    if git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
        # Case 2a: git repo → reuse scode (coding-agent/<repo> layout).
        # zsh -ic sources interactive zshrc so the scode alias resolves.
        # printf %q for bash 3.2 compat (macOS system bash); output is safe
        # for both bash and zsh parsers.
        quoted_target=$(printf '%q' "$target")
        exec zsh -ic "scode -p $quoted_target"
    else
        # Case 2b: plain dir → default sesh session (wildcard match in
        # sesh.toml still wins if applicable, e.g. /Volumes/Data/Program/*/*).
        exec sesh connect "$target"
    fi
fi

# Case 3: configured sesh session name (not a path, not an active tmux session)
exec sesh connect "$selected"
