# 10_fzf.sh - fzf configuration (shared, shell-detecting).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir.
# zsh-vi-mode wipes keybindings on init, so dot_zshrc.tmpl's
# zvm_after_init also re-sources this file. ble.sh on bash doesn't
# clobber readline binds at attach, so no equivalent re-source needed.

# Add git-installed fzf to PATH if present (Linux only).
# On macOS, fzf is managed by Homebrew (/opt/homebrew/bin/fzf) — prepending
# ~/.fzf/bin would shadow brew with a stale clone. The chezmoi external that
# clones https://github.com/junegunn/fzf is gated to non-darwin in
# .chezmoiexternal.toml.tmpl for the same reason.
case "${OSTYPE:-}" in
    linux*)
        [ -d "$HOME/.fzf/bin" ] && export PATH="$HOME/.fzf/bin:$PATH"
        ;;
esac

# Check if fzf is installed
command -v fzf >/dev/null 2>&1 || return 0

# Load fzf shell integration. fzf 0.48.0+ supports --zsh / --bash flags;
# older versions need separate script files at well-known paths.
if [ -n "$ZSH_VERSION" ]; then
    if fzf --zsh >/dev/null 2>&1; then
        source <(fzf --zsh)
    elif [ -f "$HOME/.fzf.zsh" ]; then
        . "$HOME/.fzf.zsh"
    elif [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]; then
        . /usr/share/doc/fzf/examples/key-bindings.zsh
        [ -f /usr/share/doc/fzf/examples/completion.zsh ] && \
            . /usr/share/doc/fzf/examples/completion.zsh
    fi
elif [ -n "$BASH_VERSION" ]; then
    if fzf --bash >/dev/null 2>&1; then
        source <(fzf --bash)
    elif [ -f "$HOME/.fzf.bash" ]; then
        . "$HOME/.fzf.bash"
    elif [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
        . /usr/share/doc/fzf/examples/key-bindings.bash
        [ -f /usr/share/doc/fzf/examples/completion.bash ] && \
            . /usr/share/doc/fzf/examples/completion.bash
    fi
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
