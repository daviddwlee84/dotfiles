# 56_view_ebook_completion.zsh - tab completion for `view-ebook`.
# Source CLI: dot_dotfiles/bin/executable_view-ebook. Mirrors the bash twin
# 56_view_ebook_completion.bash — keep both in sync. See docs/zsh/zsh-completions.md §F.

(( $+commands[view-ebook] )) || return 0

_view_ebook() {
    _arguments -s \
        '(-p --preview)'{-p,--preview}'[print metadata to stdout]' \
        '(-w --width)'{-w,--width}'[wrap width for --preview]:cols:' \
        '(- *)'{-h,--help}'[show help]' \
        '1:e-book file:_files -g "*.(mobi|azw|azw3|fb2|lit|pdb|prc|MOBI|AZW|AZW3|FB2|LIT|PDB|PRC)"'
}

compdef _view_ebook view-ebook
