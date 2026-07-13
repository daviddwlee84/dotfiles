# 54_wake_completion.bash - tab completion for `wake` (Wake-on-LAN sender).
# Source CLI: dot_dotfiles/bin/executable_wake.
# Mirrors dot_config/zsh/tools/54_wake_completion.zsh — keep both in sync.

command -v wake >/dev/null 2>&1 || return 0

_wake_completion() {
    local cur prev words cword
    _init_completion -n = || return

    case "$prev" in
        -b|--broadcast|-p|--port|-c|--count) return ;;
    esac

    case "$cur" in
        -*)
            COMPREPLY=( $(compgen -W "-l --list --list-names -b --broadcast -p --port -c --count -q --quiet" -- "$cur") )
            ;;
        *)
            COMPREPLY=( $(compgen -W "$(wake --list-names 2>/dev/null)" -- "$cur") )
            ;;
    esac
}

complete -F _wake_completion wake
