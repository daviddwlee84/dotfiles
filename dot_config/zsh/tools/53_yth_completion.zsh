# 53_yth_completion.zsh - tab completion for `yth` (YouTube watch-history CLI).
# Source CLI: dot_dotfiles/bin/executable_yth (hand-rolled dispatcher) +
# scripts/yth/*.py (tyro leaf modules).
#
# Note: `<video-id>` is NOT auto-completed — ids are opaque 11-char strings and
# enumerating the whole history on every TAB is wasteful. Use `tv yth` (the
# fuzzy picker) or `yth search <query>` to find ids.

(( $+commands[yth] )) || return 0

_yth() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*::arg:->args'

    case "$state" in
        subcommand)
            local -a subs=(
                'import-takeout:Backfill history from a Takeout watch-history.json'
                'sync:Incremental :ythistory sync (needs login cookies)'
                'enrich:Fetch per-video metadata (title/description/duration)'
                'fetch-subs:Download + index subtitle text'
                'search:Search title/channel/description (--subs adds captions)'
                'list:List history, newest first (--tsv feeds the tv channel)'
                'show:One-video detail (DB-only)'
                'open:Open the video in the browser'
                'copy:Copy the video URL to the clipboard'
                'play:Play in mpv if configured, else browser'
                'tv:Open the `tv yth` fuzzy picker'
            )
            _describe -t subcommands 'yth subcommand' subs
            ;;
        args)
            case "$line[1]" in
                import-takeout)
                    _arguments '1:takeout json:_files -g "*.json"'
                    ;;
                search)
                    _arguments \
                        '*:query:' \
                        '--subs[also search caption text]' \
                        '--json[emit JSON instead of a table]' \
                        '--limit=[max results]:N:' \
                        '--raw[pass query straight to FTS5]'
                    ;;
                list)
                    _arguments \
                        '--tsv[emit TSV for the tv source]' \
                        '--limit=[max rows]:N:'
                    ;;
                show)
                    _arguments '1:video-id:' '--json[emit a JSON object]'
                    ;;
                enrich)
                    _arguments \
                        '--limit=[max videos this run]:N:' \
                        '--all[enrich every pending video]' \
                        '--force[re-enrich already-enriched videos]' \
                        '--cookies[use the configured cookie source]' \
                        '--sleep=[seconds between videos]:secs:'
                    ;;
                fetch-subs)
                    _arguments \
                        '*:video-id:' \
                        '--recent=[N most-recently-watched pending]:N:' \
                        '--all[every pending video]' \
                        '--force[refetch even if already fetched]' \
                        '--cookies[use the configured cookie source]' \
                        '--langs=[subtitle languages]:langs:' \
                        '--sleep=[seconds between videos]:secs:'
                    ;;
                sync)
                    _arguments \
                        '--limit=[max history entries]:N:' \
                        '--full[ignore the saved cursor and re-scan]'
                    ;;
                open|copy|play)
                    _arguments '1:video-id:'  # opaque id, can't enumerate
                    ;;
                tv)
                    _arguments '*:tv-arg:'  # passthrough to tv
                    ;;
            esac
            ;;
    esac
}

compdef _yth yth
