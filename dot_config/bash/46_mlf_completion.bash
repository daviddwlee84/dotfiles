# 46_mlf_completion.bash - tab completion for `mlf` (MLflow umbrella CLI).
# Source CLI: dot_dotfiles/bin/executable_mlf.
# Mirrors dot_config/zsh/tools/46_mlf_completion.zsh — keep both in sync.

command -v mlf >/dev/null 2>&1 || return 0

_mlf_completion() {
    local cur prev words cword
    _init_completion -n = || return

    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "tui tv open copy plot list download" -- "$cur") )
        return
    fi

    local sub="${words[1]}"

    case "$sub" in
        list)
            if [ "$cword" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "experiments runs models" -- "$cur") )
                return
            fi
            case "$prev" in
                --experiment|--limit) return ;;
            esac
            local kind="${words[2]}"
            case "$kind" in
                runs)
                    COMPREPLY=( $(compgen -W "--experiment --limit --json" -- "$cur") )
                    ;;
                experiments|models)
                    COMPREPLY=( $(compgen -W "--limit --json" -- "$cur") )
                    ;;
            esac
            ;;
        plot)
            case "$prev" in
                --width|--height|--theme) return ;;
            esac
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--width --height --theme" -- "$cur") ) ;;
            esac
            ;;
        download)
            case "$prev" in
                --dest) _filedir -d; return ;;
            esac
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--dest" -- "$cur") ) ;;
            esac
            ;;
    esac
}

complete -F _mlf_completion mlf
