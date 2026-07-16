# 55_view_office_completion.bash - tab completion for `view-office`.
# Source CLI: dot_dotfiles/bin/executable_view-office.
# Mirrors dot_config/zsh/tools/55_view_office_completion.zsh — keep both in sync.

command -v view-office >/dev/null 2>&1 || return 0

_view_office_completion() {
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
            # Office / OpenDocument extensions (case-insensitive via _filedir).
            _filedir '@(docx|xlsx|pptx|doc|xls|ppt|odt|ods|odp|rtf|DOCX|XLSX|PPTX|DOC|XLS|PPT|ODT|ODS|ODP|RTF)'
            ;;
    esac
}

complete -F _view_office_completion view-office
