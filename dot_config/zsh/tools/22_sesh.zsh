# 22_sesh.zsh - sesh tmux session manager
# https://github.com/joshmedeski/sesh

# Check if sesh is installed
command -v sesh &>/dev/null || return 0

# Auto-generate shell completion into ~/.zfunc/ (regenerates on version change)
if [[ -d ~/.zfunc ]]; then
    local _sesh_ver="$(sesh --version 2>/dev/null)"
    if [[ ! -f ~/.zfunc/_sesh ]] || ! grep -q "${_sesh_ver}" ~/.zfunc/_sesh 2>/dev/null; then
        sesh completion zsh > ~/.zfunc/_sesh 2>/dev/null
    fi
fi

# Sesh session switcher with fzf (full-featured picker)
# Supports icons, preview, filtering by source, and session killing
function sesh-sessions() {
    {
        exec </dev/tty
        exec <&1
        local session
        session=$(sesh list --icons | fzf-tmux -p 80%,70% \
            --no-sort --ansi --border-label ' sesh ' --prompt '⚡  ' \
            --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find' \
            --bind 'tab:down,btab:up' \
            --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
            --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
            --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
            --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
            --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
            --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
            --preview-window 'right:55%' \
            --preview 'sesh preview {}' \
        )
        zle reset-prompt > /dev/null 2>&1 || true
        [[ -z "$session" ]] && return
        sesh connect "$session"
    }
}

# Register as zsh widget
zle -N sesh-sessions

# Key bindings (Alt+S for session switcher, avoids conflict with Ctrl+A tmux prefix)
bindkey -M emacs '\es' sesh-sessions
bindkey -M viins '\es' sesh-sessions
bindkey -M vicmd '\es' sesh-sessions
