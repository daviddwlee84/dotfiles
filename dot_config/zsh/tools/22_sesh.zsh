# 22_sesh.zsh - sesh tmux session manager
# https://github.com/joshmedeski/sesh

# Check if sesh is installed
command -v sesh &>/dev/null || return 0

# Sesh session switcher with fzf
# Integrates tmux sessions, zoxide directories, and config-defined sessions
function sesh-sessions() {
    local session
    session=$(sesh list -t -c | fzf --height 40% --reverse \
        --border-label ' sesh ' --border --prompt '⚡  ')
    [[ -z "$session" ]] && return
    sesh connect "$session"
}

# Register as zsh widget
zle -N sesh-sessions

# Key bindings (Ctrl+A for session switcher)
# Works in both emacs and vi modes
bindkey -M emacs '^A' sesh-sessions
bindkey -M viins '^A' sesh-sessions
bindkey -M vicmd '^A' sesh-sessions
