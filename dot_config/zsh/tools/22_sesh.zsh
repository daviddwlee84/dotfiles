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

# Connect to a sesh session for the current directory (creates it if missing).
# Smart argument handling:
#   shere                              # default startup_command (nvim)
#   shere specstory run codex          # bare args → treated as command
#   shere -c "specstory run codex"     # explicit --command flag
#   shere -p ~/my-proj                 # explicit path
#   shere -p ~/my-proj npm run dev     # explicit path + command
function sesh-here() {
    local cmd="" path=""
    # Parse flags first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--command) cmd="$2"; shift 2 ;;
            -p|--path)    path="$2"; shift 2 ;;
            -*)           echo "sesh-here: unknown flag $1" >&2; return 1 ;;
            *)            break ;;  # remaining args are the command
        esac
    done
    # Remaining positional args become the command
    [[ $# -gt 0 && -z "$cmd" ]] && cmd="$*"
    path="${path:-$PWD}"
    if [[ -n "$cmd" ]]; then
        sesh connect --command "$cmd" "$path"
    else
        sesh connect "$path"
    fi
}

# Connect to the current git root when available, otherwise use $PWD.
# Same smart argument handling as sesh-here.
#   sroot                              # default startup_command
#   sroot specstory run codex          # bare args → command
#   sroot -c "specstory run codex"     # explicit --command flag
function sesh-root() {
    local cmd="" root
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--command) cmd="$2"; shift 2 ;;
            -*)           shift ;;
            *)            break ;;
        esac
    done
    [[ $# -gt 0 && -z "$cmd" ]] && cmd="$*"
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
    if [[ -n "$cmd" ]]; then
        sesh connect --command "$cmd" "$root"
    else
        sesh connect "$root"
    fi
}

alias shere='sesh-here'
alias sroot='sesh-root'

# Register as zsh widget
zle -N sesh-sessions

# Key bindings (Alt+S for session switcher, avoids conflict with Ctrl+A tmux prefix)
bindkey -M emacs '\es' sesh-sessions
bindkey -M viins '\es' sesh-sessions
bindkey -M vicmd '\es' sesh-sessions
