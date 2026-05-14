# 49_x_completion.zsh - tab completion for `x` (clipboard / open helper).
# Source CLI: dot_dotfiles/bin/executable_x (bash hand-rolled subcommand parser).
# Loaded eagerly by load_modular_dir AFTER compinit in dot_zshrc.tmpl, so
# `compdef _x x` is safe.

(( $+commands[x] )) || return 0

_x() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*::arg:->args'

    case "$state" in
        subcommand)
            local -a subs=(
                'copy:Copy stdin or FILE to system clipboard'
                'paste:Paste clipboard contents to stdout'
                'open:Open URL or path with system handler'
                'help:Show usage'
            )
            _describe -t subcommands 'x subcommand' subs
            ;;
        args)
            case "$line[1]" in
                copy)
                    _arguments \
                        '--force[copy even if file looks like a private key]' \
                        '*:file:_files'
                    ;;
                open)
                    _arguments '*:target:_files'
                    ;;
            esac
            ;;
    esac
}

compdef _x x
