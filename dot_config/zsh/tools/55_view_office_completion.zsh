# 55_view_office_completion.zsh - tab completion for `view-office`.
# Source CLI: dot_dotfiles/bin/executable_view-office. Mirrors the bash twin
# 55_view_office_completion.bash — keep both in sync. See docs/zsh/zsh-completions.md §F.

(( $+commands[view-office] )) || return 0

_view_office() {
    _arguments -s \
        '(-p --preview)'{-p,--preview}'[render to stdout instead of a TUI]' \
        '(-w --width)'{-w,--width}'[wrap width for --preview]:cols:' \
        '(- *)'{-h,--help}'[show help]' \
        '1:office file:_files -g "*.(docx|xlsx|pptx|doc|xls|ppt|odt|ods|odp|rtf|DOCX|XLSX|PPTX|DOC|XLS|PPT|ODT|ODS|ODP|RTF)"'
}

compdef _view_office view-office
