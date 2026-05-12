# 38_workmux.sh - Workmux (`workmux` / `wm`) tmux + git-worktree orchestrator
# (shared bash + zsh). Moved from dot_config/zsh/tools/38_workmux.zsh; the
# only zsh-ism was `${(@f)$(cmd)}` (split-on-newlines flag), rewritten as a
# `while IFS= read -r` loop.
#
# https://workmux.raine.dev — github.com/raine/workmux
#
# Companion config: ~/.config/workmux/config.yaml (managed by chezmoi at
# dot_config/workmux/config.yaml). See docs/tools/workmux.md for the full
# story (worktrunk vs workmux split, status icon lifecycle, leak mitigation).
#
# Why a separate file from 37_worktrunk.{sh,zsh}: the two tools coexist
# (worktrunk = `wt` for git-worktree CLI / aliases, workmux = `wm` for status
# icons + dashboard + sidebar). Separate files keep the rationale + helpers
# per-tool and let users disable one independently.

# Skip silently if not installed (Linux ansible install can fail offline,
# Cargo path may not be present, etc.)
command -v workmux &>/dev/null || return 0

# ── Manual marker cleanup ──────────────────────────────────────────────────
#
# The `working` (🤖) status workmux sets is *sticky* — it never auto-clears
# on its own. `waiting` (💬) and `done` (✅) auto-clear when you focus the
# window, but `working` only goes away when:
#   1. The agent's plugin/hook explicitly calls `workmux set-window-status done`
#      (Claude Stop / OpenCode session.idle), OR
#   2. `workmux sidebar` is running and detects 10s of pane silence
#      (interrupted-agent detection), OR
#   3. You manually clear it.
#
# Path #1 fails when the agent is killed before its Stop/idle handler fires
# (Ctrl+C, terminal crash, OOM). Path #2 requires keeping a sidebar pane open.
# `wmclear` is the manual escape hatch.
#
# Without arg: clears the marker for the current tmux window.
# With arg:    `wmclear 5` clears window 5 in the current session.
# Pass `--all` to nuke every workmux marker in the current session.
function wmclear() {
    if [[ "$1" == "--all" ]]; then
        # Walk every window in the current session and unset the user-var.
        # Original zsh code used `windows=("${(@f)$(...)}")` to split command
        # output on newlines; the `while IFS= read -r` loop below is the
        # portable equivalent (works in bash + zsh).
        local sess
        sess=$(tmux display -p '#{session_name}' 2>/dev/null) || return 1
        local -a windows
        windows=()
        local w
        while IFS= read -r w; do
            [ -n "$w" ] && windows+=( "$w" )
        done < <(tmux list-windows -t "$sess" -F '#{window_index}' 2>/dev/null)
        for w in "${windows[@]}"; do
            tmux set-option -w -t "${sess}:${w}" -u '@workmux_status' 2>/dev/null
        done
        echo "Cleared @workmux_status on ${#windows[@]} windows in session $sess"
        return 0
    fi

    if [[ -n "$1" ]]; then
        # Specific window: use workmux's own clear command (handles agent
        # state too, not just the tmux user-var)
        local sess win
        sess=$(tmux display -p '#{session_name}' 2>/dev/null) || return 1
        win="$1"
        tmux set-option -w -t "${sess}:${win}" -u '@workmux_status' 2>/dev/null
        echo "Cleared @workmux_status on ${sess}:${win}"
        return 0
    fi

    # Current window: prefer workmux's clear so it also resets agent state
    workmux set-window-status clear 2>/dev/null
}

# ── Sidebar daemon convenience ─────────────────────────────────────────────
#
# `workmux sidebar` is what enables the "interrupted agent" auto-clear (10s
# pane-silence heuristic). Without it, `working` markers leak forever on
# crashed agents. NOT auto-started here because it spawns a tmux pane and
# many users want to opt-in. Use `wmsb` to toggle.
alias wmsb='workmux sidebar'

# ── Short aliases mirroring upstream's recommendation ──────────────────────
# README explicitly suggests `alias wm='workmux'`. The Linux ansible install
# also creates a `wm` symlink in ~/.local/bin so this alias is redundant on
# Linux, but on macOS Homebrew installs only `workmux`, so define it here.
if ! command -v wm &>/dev/null; then
    alias wm='workmux'
fi
