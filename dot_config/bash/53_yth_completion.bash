# 53_yth_completion.bash - tab completion for `yth` (YouTube watch-history CLI).
# Source CLI: dot_dotfiles/bin/executable_yth.
# Mirrors dot_config/zsh/tools/53_yth_completion.zsh — keep both in sync.

command -v yth >/dev/null 2>&1 || return 0

_yth_completion() {
    local cur prev words cword
    _init_completion -n = || return

    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "import-takeout sync enrich fetch-subs search list show open copy play tv" -- "$cur") )
        return
    fi

    local sub="${words[1]}"

    case "$sub" in
        import-takeout)
            _filedir json
            ;;
        search)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--subs --json --limit --raw" -- "$cur") ) ;;
            esac
            ;;
        list)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--tsv --limit" -- "$cur") ) ;;
            esac
            ;;
        show)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
            esac
            ;;
        enrich)
            case "$prev" in
                --limit|--sleep) return ;;
            esac
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--limit --all --force --cookies --sleep" -- "$cur") ) ;;
            esac
            ;;
        fetch-subs)
            case "$prev" in
                --recent|--langs|--sleep) return ;;
            esac
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--recent --all --force --cookies --langs --sleep" -- "$cur") ) ;;
            esac
            ;;
        sync)
            case "$prev" in
                --limit) return ;;
            esac
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--limit --full" -- "$cur") ) ;;
            esac
            ;;
    esac
}

complete -F _yth_completion yth
