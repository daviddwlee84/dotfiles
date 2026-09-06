# editorcfg and its filename-only launcher.
_editorcfg() {
    if (( CURRENT == 3 )) && [[ ${words[2]} == use ]]; then
        compadd -- nvim micro vim nano code cursor
    elif (( CURRENT == 2 )); then
        compadd -- status list doctor use reset help
    fi
}
compdef _editorcfg editorcfg
compdef _files dotfiles-editor
