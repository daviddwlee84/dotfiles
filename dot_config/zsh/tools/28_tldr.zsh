# 28_tldr.zsh - tldr language preference helper

# Language preference order for tldrf fallback.
typeset -ga TLDR_LANGUAGES=(zh_TW zh en)

tldrf() {
    command -v tldr &>/dev/null || return 127

    local -a lang_flags
    local lang
    for lang in "${TLDR_LANGUAGES[@]}"; do
        lang_flags+=(-L "$lang")
    done

    command tldr "${lang_flags[@]}" "$@"
}
