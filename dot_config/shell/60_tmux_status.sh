# ~/.config/shell/60_tmux_status.sh
# Source: dot_config/shell/60_tmux_status.sh (managed by chezmoi)
#
# Generic per-window tmux status badge helpers — POSIX, sourced by both
# zsh and bash. Thin convenience layer over the same primitive workmux
# uses (`tmux set-option -w '@<name>_status' '<glyph>'`), so any script /
# hook / cron job / build watcher can tag its tmux window without
# pulling in workmux.
#
# Why a shared layer (not in 38_workmux.zsh): these helpers don't need
# any zsh feature, and the most common consumers (build scripts, deploy
# hooks, CI wrappers) tend to be `#!/bin/bash` or `#!/bin/sh`. Putting
# them in dot_config/shell/ means they Just Work from any shell.
#
# Companion: docs/tools/workmux.md → "Reusing the per-window status
# mechanism (without workmux)" for design rationale, the lifecycle hard
# rules, and the build-watcher worked example.
#
# Quick reference:
#
#   tmux_status_set my_build 🔨           # tag current window
#   tmux_status_set my_build 🔨 mysess:3  # tag specific window
#   tmux_status_get my_build              # read current window
#   tmux_status_clear my_build            # unset (current window)
#   tmux_status_clear my_build mysess:3   # unset specific window
#   tmux_status_clear_all my_build        # unset across every session
#   tmux_status_list                      # list every @*_status user-var
#   tmux_status_run my_build 🔨 ✅ ❌ -- npm run build
#                                         # set 🔨, run cmd, set ✅/❌
#                                         # by exit code, auto-clear on
#                                         # signal trap
#
# Naming convention: pass the LOGICAL name without `@` or `_status`
# suffix — these helpers add the `@<name>_status` wrapper. So
# `tmux_status_set my_build 🔨` writes `@my_build_status`. This keeps
# the user-var namespace tidy (`@<tool>_status` everywhere) and lets
# you grep for "every status producer" with `tmux_status_list`.

# Skip silently if tmux isn't on PATH (cron, headless SSH, fresh box
# pre-ansible). Producers can call these unconditionally.
command -v tmux >/dev/null 2>&1 || return 0

# Internal: validate name (alphanumeric + underscore + dash, no `@` /
# `_status` since we add them). Returns 0 if valid, 1 if not (with
# stderr diagnostic). Empty name is rejected. Names starting with
# `workmux` are reserved to avoid clobbering workmux's own user-var.
_tmux_status_validate_name() {
    if [ -z "${1:-}" ]; then
        printf 'tmux_status: name argument is required\n' >&2
        return 1
    fi
    case "$1" in
        workmux*)
            # shellcheck disable=SC2016 # Backticks here are literal Markdown-style code spans, not command substitution.
            printf 'tmux_status: name "%s" reserved (workmux owns @workmux_status). Use `workmux set-window-status` for the agent path.\n' "$1" >&2
            return 1
            ;;
        *[!A-Za-z0-9_-]*)
            printf 'tmux_status: name "%s" must be [A-Za-z0-9_-]+\n' "$1" >&2
            return 1
            ;;
    esac
    return 0
}

# tmux_status_set <name> <glyph> [target]
#   target defaults to current window (`tmux display -p '#{session_name}:#{window_index}'`)
tmux_status_set() {
    _tmux_status_validate_name "${1:-}" || return 1
    if [ $# -lt 2 ]; then
        printf 'tmux_status_set: usage: tmux_status_set <name> <glyph> [target]\n' >&2
        return 1
    fi
    _name="$1"
    _glyph="$2"
    _target="${3:-}"
    if [ -n "$_target" ]; then
        tmux set-option -w -t "$_target" "@${_name}_status" "$_glyph" 2>/dev/null
    else
        tmux set-option -w "@${_name}_status" "$_glyph" 2>/dev/null
    fi
}

# tmux_status_get <name> [target]
#   prints the glyph (or empty string + non-zero exit if unset)
tmux_status_get() {
    _tmux_status_validate_name "${1:-}" || return 1
    _name="$1"
    _target="${2:-}"
    if [ -n "$_target" ]; then
        tmux show-options -wv -t "$_target" "@${_name}_status" 2>/dev/null
    else
        tmux show-options -wv "@${_name}_status" 2>/dev/null
    fi
}

# tmux_status_clear <name> [target]
tmux_status_clear() {
    _tmux_status_validate_name "${1:-}" || return 1
    _name="$1"
    _target="${2:-}"
    if [ -n "$_target" ]; then
        tmux set-option -w -t "$_target" -u "@${_name}_status" 2>/dev/null
    else
        tmux set-option -w -u "@${_name}_status" 2>/dev/null
    fi
}

# tmux_status_clear_all <name>
#   walk every window in every session, unset @<name>_status
tmux_status_clear_all() {
    _tmux_status_validate_name "${1:-}" || return 1
    _name="$1"
    tmux list-windows -aF '#{session_name}:#{window_index}' 2>/dev/null | while IFS= read -r _w; do
        tmux set-option -w -t "$_w" -u "@${_name}_status" 2>/dev/null
    done
}

# tmux_status_list
#   show every @*_status user-var across every window (read-only audit)
tmux_status_list() {
    tmux list-windows -aF '#{session_name}:#{window_index} #{window_name}' 2>/dev/null | while IFS= read -r _line; do
        _w="${_line%% *}"
        # Pull every option starting with @ on this window, filter to *_status
        tmux show-options -w -t "$_w" 2>/dev/null \
            | awk -v w="$_line" '/^@[A-Za-z0-9_-]+_status / {print w "  " $0}'
    done
}

# tmux_status_run <name> <working_glyph> <ok_glyph> <fail_glyph> -- <cmd> [args...]
#   Run a command, badge the window with `working_glyph` while it runs,
#   then `ok_glyph` on success or `fail_glyph` on failure. Traps INT /
#   TERM / HUP to clear the badge instead of leaking on Ctrl+C.
#
#   Example:
#     tmux_status_run my_build 🔨 ✅ ❌ -- npm run build
#     tmux_status_run deploy   🚀 🟢 🔴 -- ./deploy.sh prod
tmux_status_run() {
    _tmux_status_validate_name "${1:-}" || return 1
    if [ $# -lt 6 ]; then
        printf 'tmux_status_run: usage: tmux_status_run <name> <working> <ok> <fail> -- <cmd> [args...]\n' >&2
        return 1
    fi
    _name="$1"
    _working="$2"
    _ok="$3"
    _fail="$4"
    shift 4
    if [ "${1:-}" != "--" ]; then
        # shellcheck disable=SC2016 # Backticks are literal in the diagnostic message.
        printf 'tmux_status_run: missing `--` separator before command\n' >&2
        return 1
    fi
    shift
    if [ $# -eq 0 ]; then
        # shellcheck disable=SC2016 # Backticks are literal in the diagnostic message.
        printf 'tmux_status_run: no command after `--`\n' >&2
        return 1
    fi

    # Capture target ONCE up front — if `cmd` happens to switch tmux
    # window, we still want the badge to land on the window the user
    # invoked from.
    _target=$(tmux display -p '#{session_name}:#{window_index}' 2>/dev/null)
    [ -z "$_target" ] && _target=""

    # Trap so Ctrl+C / kill doesn't leak the working glyph forever.
    # Use a trap that clears, then re-raises the signal default for
    # correct exit semantics.
    trap '_tmux_status_run_trap "$_name" "$_target"' INT TERM HUP

    tmux_status_set "$_name" "$_working" "$_target"
    "$@"
    _rc=$?
    if [ $_rc -eq 0 ]; then
        tmux_status_set "$_name" "$_ok" "$_target"
    else
        tmux_status_set "$_name" "$_fail" "$_target"
    fi

    trap - INT TERM HUP
    return $_rc
}

# Internal: trap helper for tmux_status_run. Clears the badge then
# re-raises the signal so the calling shell sees correct $? / exit code.
_tmux_status_run_trap() {
    tmux_status_clear "$1" "$2" 2>/dev/null
    trap - INT TERM HUP
    # Re-raise INT (most common case); for TERM/HUP we just let the
    # shell continue — calling scripts can decide what to do via $?.
    kill -INT $$ 2>/dev/null
}
