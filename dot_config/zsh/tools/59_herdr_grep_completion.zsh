# 59_herdr_grep_completion.zsh - tab completion for `herdr-grep`.
# Source CLI: dot_dotfiles/bin/executable_herdr-grep. Mirrors the bash twin
# 59_herdr_grep_completion.bash — keep both in sync. See docs/zsh/zsh-completions.md §F.

(( $+commands[herdr-grep] )) || return 0

_herdr_grep() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C -s \
        '(- *)'{-h,--help}'[show help]' \
        '(-F --fixed-strings)'{-F,--fixed-strings}'[treat PATTERN as a literal string]' \
        '(-i --ignore-case)'{-i,--ignore-case}'[search case-insensitively]' \
        '(--source --visible)--source=[pane content source]:source:(visible recent recent-unwrapped)' \
        '(--source)--visible[search only the visible pane screen]' \
        '(--session --all-sessions)--session=[search one running named session]:session:->session' \
        '(--session)--all-sessions[search every running local session]' \
        '(--json --pick)--json[emit one structured JSON document]' \
        '(--json)--pick[choose a match with fzf, then focus or attach its pane]' \
        '--list-sessions[print running session names for shell completion]' \
        '1:pattern:'

    case "$state" in
        session)
            local -a sessions
            sessions=(${(f)"$(herdr-grep --list-sessions 2>/dev/null)"})
            (( ${#sessions} )) && _describe -t sessions 'herdr session' sessions
            ;;
    esac
}

compdef _herdr_grep herdr-grep
