# 59_herdr_grep_completion.bash - tab completion for `herdr-grep`.
# Source CLI: dot_dotfiles/bin/executable_herdr-grep.
# Mirrors dot_config/zsh/tools/59_herdr_grep_completion.zsh — keep both in sync.
# Register unconditionally: bash loads this directory before the shared PATH layer
# adds ~/.dotfiles/bin, while `herdr-grep` itself is always deployed.

_herdr_grep_completion() {
    local cur prev words cword
    _init_completion -n = || return

    case "$prev" in
        --source)
            COMPREPLY=( $(compgen -W "visible recent recent-unwrapped" -- "$cur") )
            return
            ;;
        --session)
            local sessions
            sessions=$(herdr-grep --list-sessions 2>/dev/null)
            COMPREPLY=( $(compgen -W "$sessions" -- "$cur") )
            return
            ;;
    esac

    case "$cur" in
        -*)
            local opts="-h --help -F --fixed-strings -i --ignore-case --source --visible --session --all-sessions --json --pick --list-sessions"
            COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            ;;
        *)
            # PATTERN is free-form; do not offer filesystem or server candidates.
            COMPREPLY=()
            ;;
    esac
}

complete -F _herdr_grep_completion herdr-grep
