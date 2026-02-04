# 10_fzf.zsh - fzf configuration

# Add git-installed fzf to PATH if present
[[ -d "$HOME/.fzf/bin" ]] && export PATH="$HOME/.fzf/bin:$PATH"

# Check if fzf is installed
command -v fzf &>/dev/null || return 0

# Load fzf shell integration
# fzf 0.48.0+ supports --zsh flag, older versions need separate script files
if fzf --zsh &>/dev/null; then
    source <(fzf --zsh)
elif [[ -f ~/.fzf.zsh ]]; then
    # Git-installed fzf (if install script was run with shell integration)
    source ~/.fzf.zsh
elif [[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]]; then
    # Debian/Ubuntu apt-installed fzf (fallback for old versions)
    source /usr/share/doc/fzf/examples/key-bindings.zsh
    [[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh
fi

# Default options
export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border"

# Use fd for fzf if available (faster than find)
if command -v fd &>/dev/null; then
    export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"
fi

# Use bat for file preview (Ctrl+T) if available
if command -v bat &>/dev/null; then
    export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"
fi

# Use eza for directory preview (Alt+C) if available
if command -v eza &>/dev/null; then
    export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"
fi

# Advanced: Tab completion preview behavior
_fzf_comprun() {
    local command=$1
    shift

    case "$command" in
        cd)
            if command -v eza &>/dev/null; then
                fzf --preview 'eza --tree --color=always {} | head -200' "$@"
            else
                fzf --preview 'tree -C {} | head -200' "$@"
            fi
            ;;
        export|unset)
            fzf --preview "eval 'echo \$'{}" "$@"
            ;;
        ssh)
            fzf --preview 'dig {}' "$@"
            ;;
        *)
            if command -v bat &>/dev/null; then
                fzf --preview 'bat -n --color=always --line-range :500 {}' "$@"
            else
                fzf --preview 'head -500 {}' "$@"
            fi
            ;;
    esac
}
