# 60_ytmv_completion.bash - tab completion for `ytmv` (YouTube MV -> old MP3 players).
# Source CLI: dot_dotfiles/bin/executable_ytmv.
# Mirrors dot_config/zsh/tools/60_ytmv_completion.zsh — keep both in sync.

command -v ytmv >/dev/null 2>&1 || return 0

_ytmv_profile_list() {
    ytmv doctor --list-profiles 2>/dev/null
}

_ytmv_completion() {
    local cur prev words cword
    _init_completion -n = || return

    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "get lyrics tag doctor" -- "$cur") )
        return
    fi

    local sub="${words[1]}"

    # Value slots shared by every subcommand: offer the right candidates and
    # stop, so a filename never leaks into an enum argument.
    case "$prev" in
        --profile)
            COMPREPLY=( $(compgen -W "$(_ytmv_profile_list)" -- "$cur") ); return ;;
        --id3-version)
            COMPREPLY=( $(compgen -W "3 4" -- "$cur") ); return ;;
        --id3-encoding)
            COMPREPLY=( $(compgen -W "utf16 utf8 latin1 raw-big5 raw-gbk" -- "$cur") ); return ;;
        --lrc-encoding)
            COMPREPLY=( $(compgen -W "utf-8 utf-8-sig cp950 gbk" -- "$cur") ); return ;;
        --lrc-on-unencodable)
            COMPREPLY=( $(compgen -W "strict replace" -- "$cur") ); return ;;
        --lyrics)
            COMPREPLY=( $(compgen -W "auto lrclib youtube none" -- "$cur") ); return ;;
        --out)
            _filedir -d; return ;;
        --from-file)
            _filedir; return ;;
        --artist|--track|--album|--year|--langs|--m3u|--max-height|--audio-quality|--sleep|--cover-max)
            return ;;
    esac

    local common_overrides="--id3-version --id3-encoding --lrc-encoding --lrc-on-unencodable \
--skip-lrc-sidecar --skip-embed-lyrics --embed-sylt --cover-max --skip-cover --ascii-filenames"

    case "$sub" in
        get)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--from-file --out --profile --audio --video \
--soft-subs --burn-subs --lyrics --langs --artist --track --album --number --m3u \
--max-height --audio-quality --cookies --force --sleep --refresh-lyrics --json \
$common_overrides" -- "$cur") ) ;;
            esac
            ;;
        lyrics)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--profile --artist --track --album --pick \
--force --refresh-lyrics --sleep --json $common_overrides" -- "$cur") ) ;;
                *) _filedir mp3 ;;
            esac
            ;;
        tag)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--profile --artist --track --album --year \
--rename --dry-run $common_overrides" -- "$cur") ) ;;
                *) _filedir ;;
            esac
            ;;
        doctor)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--profile --list-profiles --offline --json" \
-- "$cur") ) ;;
            esac
            ;;
    esac
}

complete -F _ytmv_completion ytmv
