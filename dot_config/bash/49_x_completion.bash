# 49_x_completion.bash - tab completion for `x` (clipboard / open helper).
# Source CLI: dot_dotfiles/bin/executable_x.
# Loaded by load_modular_dir AFTER 03_completion.bash (bash-completion v2),
# so `_init_completion` is available.

command -v x >/dev/null 2>&1 || return 0

_x_completion() {
    local cur prev words cword
    _init_completion || return

    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "copy paste open help" -- "$cur") )
        return
    fi

    local sub="${words[1]}"
    case "$sub" in
        copy)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--force --help" -- "$cur") ) ;;
                *)  _filedir ;;
            esac
            ;;
        open)
            _filedir
            ;;
    esac
}

complete -F _x_completion x
