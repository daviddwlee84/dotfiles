# 56_view_ebook_completion.bash - tab completion for `view-ebook`.
# Source CLI: dot_dotfiles/bin/executable_view-ebook.
# Mirrors dot_config/zsh/tools/56_view_ebook_completion.zsh — keep both in sync.

command -v view-ebook >/dev/null 2>&1 || return 0

_view_ebook_completion() {
    local cur prev words cword
    _init_completion -n = || return

    case "$prev" in
        -w|--width) return ;;
    esac

    case "$cur" in
        -*)
            COMPREPLY=( $(compgen -W "-p --preview -w --width -h --help" -- "$cur") )
            ;;
        *)
            # E-book extensions calibre reads (case-insensitive via _filedir).
            _filedir '@(mobi|azw|azw3|fb2|lit|pdb|prc|MOBI|AZW|AZW3|FB2|LIT|PDB|PRC)'
            ;;
    esac
}

complete -F _view_ebook_completion view-ebook
