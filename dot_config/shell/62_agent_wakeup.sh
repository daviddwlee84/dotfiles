# 62_agent_wakeup.sh - agent quota wakeup helpers for tmux panes.
# Shared by zsh and bash. The implementation lives in
# ~/.config/television/agent-wakeup.py so TV channels, shell functions, and
# pueue scheduled jobs all share one code path.

_agent_wakeup_script() {
    if [ -n "${AGENT_WAKEUP_SCRIPT:-}" ]; then
        printf '%s\n' "$AGENT_WAKEUP_SCRIPT"
    else
        printf '%s\n' "$HOME/.config/television/agent-wakeup.py"
    fi
}

agent-wakeup() {
    _aw_script="$(_agent_wakeup_script)"
    if [ -z "$_aw_script" ] || [ ! -x "$_aw_script" ]; then
        printf 'agent-wakeup: %s not executable (run chezmoi apply?)\n' "$_aw_script" >&2
        unset _aw_script
        return 127
    fi
    "$_aw_script" "$@"
    _aw_rc=$?
    unset _aw_script
    return "$_aw_rc"
}

agent-continue-at() {
    agent-wakeup schedule "$@"
}
