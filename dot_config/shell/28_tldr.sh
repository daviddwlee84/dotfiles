# 28_tldr.sh - tldr language preference helper (shared bash + zsh).
# Moved from dot_config/zsh/tools/28_tldr.zsh; `typeset -ga` (zsh global
# array declaration) replaced with a plain top-level array assignment that
# works in both shells.

# Language preference order for tldrf fallback.
TLDR_LANGUAGES=(zh_TW zh en)

tldrf() {
    command -v tldr &>/dev/null || return 127

    local -a lang_flags
    lang_flags=()
    local lang
    for lang in "${TLDR_LANGUAGES[@]}"; do
        lang_flags+=(-L "$lang")
    done

    command tldr "${lang_flags[@]}" "$@"
}
