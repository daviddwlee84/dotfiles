# Keep presets/verbs in sync with the zsh sibling.
_editorcfg_completion() {
    local cur=${COMP_WORDS[COMP_CWORD]} candidates=''
    if [ "$COMP_CWORD" -eq 1 ]; then
        candidates='status list doctor use reset help'
    elif [ "$COMP_CWORD" -eq 2 ] && [ "${COMP_WORDS[1]}" = use ]; then
        candidates='nvim micro vim nano code cursor'
    fi
    COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
}
complete -F _editorcfg_completion editorcfg
complete -f dotfiles-editor
