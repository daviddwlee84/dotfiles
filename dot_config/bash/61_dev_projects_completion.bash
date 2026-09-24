# Static completion: never scan repositories while loading a shell.
# Keep aligned with dot_config/zsh/tools/61_dev_projects_completion.zsh.
_dev_projects_completion() {
    local cur prev words cword
    _init_completion -n = || return
    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W 'list open sidecar-import --help' -- "$cur") )
        return
    fi
    case "$prev" in
        --tool) COMPREPLY=( $(compgen -W 'sidecar nvim' -- "$cur") ); return ;;
        --config) _filedir; return ;;
        --repo) _filedir -d; return ;;
    esac
    case "${words[1]}" in
        list) COMPREPLY=( $(compgen -W '--json --help' -- "$cur") ) ;;
        open)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W '--tool --help' -- "$cur") ) ;;
                *) _filedir -d ;;
            esac
            ;;
        sidecar-import)
            COMPREPLY=( $(compgen -W '--config --repo --apply --yes --json --help' -- "$cur") )
            ;;
    esac
}
complete -F _dev_projects_completion dev-projects
