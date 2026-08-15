# 60_ytmv_completion.zsh - tab completion for `ytmv` (YouTube MV -> old MP3 players).
# Source CLI: dot_dotfiles/bin/executable_ytmv (hand-rolled dispatcher) +
# scripts/ytmv/*.py (tyro leaf modules).
# Mirrors dot_config/bash/60_ytmv_completion.bash — keep both in sync.
#
# Profile names ARE completed (a small fixed built-in list, plus whatever the
# user defined) via `ytmv doctor --list-profiles`. URLs and video ids are NOT —
# they are opaque and there is no local index to enumerate.

(( $+commands[ytmv] )) || return 0

_ytmv_profiles() {
    local -a profiles
    profiles=( ${(f)"$(ytmv doctor --list-profiles 2>/dev/null)"} )
    (( ${#profiles} )) && _describe -t profiles 'player profile' profiles
}

_ytmv() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*::arg:->args'

    case "$state" in
        subcommand)
            local -a subs=(
                'get:Download + convert + tag + attach lyrics'
                'lyrics:Find and attach lyrics to mp3s you already have'
                'tag:Re-apply a player profile in place (offline)'
                'doctor:Probe yt-dlp / ffmpeg / libass / cookies + show the profile'
            )
            _describe -t subcommands 'ytmv subcommand' subs
            ;;
        args)
            case "$line[1]" in
                get)
                    _arguments \
                        '*:url:' \
                        '--from-file=[read URLs from a file, one per line]:file:_files' \
                        '--out=[output directory]:dir:_files -/' \
                        '--profile=[player compatibility profile]:profile:_ytmv_profiles' \
                        '--audio[produce an mp3 (default)]' \
                        '--video[also produce an mp4]' \
                        '--soft-subs[embed subtitles as an mp4 track]' \
                        '--burn-subs[burn lyrics into the picture (needs libass)]' \
                        '--lyrics=[lyrics source]:source:(auto lrclib youtube none)' \
                        '--langs=[caption languages to try]:langs:' \
                        '--artist=[override artist]:artist:' \
                        '--track=[override title]:track:' \
                        '--album=[override album]:album:' \
                        '--number[prefix filenames with 01 - ]' \
                        '--m3u=[write an .m3u playlist with this name]:name:' \
                        '--max-height=[cap video height, e.g. 480]:px:' \
                        '--audio-quality=[LAME VBR quality 0 (best) .. 9]:q:' \
                        '--cookies[use yth'"'"'s configured cookie source]' \
                        '--force[re-download even if the target exists]' \
                        '--sleep=[seconds between items]:secs:' \
                        '--refresh-lyrics[bypass the LRCLIB response cache]' \
                        '--json[emit a JSON report]' \
                        '--id3-version=[force ID3 major version]:v:(3 4)' \
                        '--id3-encoding=[ID3 text frame encoding]:enc:(utf16 utf8 latin1 raw-big5 raw-gbk)' \
                        '--lrc-encoding=[sidecar .lrc encoding]:enc:(utf-8 utf-8-sig cp950 gbk)' \
                        '--lrc-on-unencodable=[behaviour on unencodable chars]:mode:(strict replace)' \
                        '--skip-lrc-sidecar[do not write the sidecar .lrc]' \
                        '--skip-embed-lyrics[do not write a USLT frame]' \
                        '--embed-sylt[also write a SYLT frame]' \
                        '--cover-max=[longest cover edge in px]:px:' \
                        '--skip-cover[do not embed cover art]' \
                        '--ascii-filenames[transliterate filenames to ASCII]'
                    ;;
                lyrics)
                    _arguments \
                        '*:mp3 file:_files -g "*.mp3"' \
                        '--profile=[player compatibility profile]:profile:_ytmv_profiles' \
                        '--artist=[force the artist used for lookup]:artist:' \
                        '--track=[force the title used for lookup]:track:' \
                        '--album=[album, sharpens the exact lookup]:album:' \
                        '--pick[choose among LRCLIB candidates interactively]' \
                        '--force[refetch even when a sidecar .lrc exists]' \
                        '--refresh-lyrics[bypass the LRCLIB response cache]' \
                        '--sleep=[seconds between files]:secs:' \
                        '--json[emit a JSON report]' \
                        '--lrc-encoding=[sidecar .lrc encoding]:enc:(utf-8 utf-8-sig cp950 gbk)' \
                        '--lrc-on-unencodable=[behaviour on unencodable chars]:mode:(strict replace)' \
                        '--skip-lrc-sidecar[embed only, no sidecar file]' \
                        '--skip-embed-lyrics[sidecar only, no USLT frame]' \
                        '--embed-sylt[also write a SYLT frame]' \
                        '--id3-version=[force ID3 major version]:v:(3 4)' \
                        '--id3-encoding=[ID3 text frame encoding]:enc:(utf16 utf8 latin1 raw-big5 raw-gbk)' \
                        '--cover-max=[longest cover edge in px]:px:' \
                        '--skip-cover[do not embed cover art]' \
                        '--ascii-filenames[transliterate filenames to ASCII]'
                    ;;
                tag)
                    _arguments \
                        '*:mp3 file or dir:_files' \
                        '--profile=[player compatibility profile]:profile:_ytmv_profiles' \
                        '--artist=[override artist]:artist:' \
                        '--track=[override title]:track:' \
                        '--album=[override album]:album:' \
                        '--year=[override year]:year:' \
                        '--rename[rewrite filenames through the sanitiser]' \
                        '--dry-run[report what would change, write nothing]' \
                        '--id3-version=[force ID3 major version]:v:(3 4)' \
                        '--id3-encoding=[ID3 text frame encoding]:enc:(utf16 utf8 latin1 raw-big5 raw-gbk)' \
                        '--lrc-encoding=[sidecar .lrc encoding]:enc:(utf-8 utf-8-sig cp950 gbk)' \
                        '--lrc-on-unencodable=[behaviour on unencodable chars]:mode:(strict replace)' \
                        '--skip-lrc-sidecar[do not write the sidecar .lrc]' \
                        '--skip-embed-lyrics[do not write a USLT frame]' \
                        '--embed-sylt[also write a SYLT frame]' \
                        '--cover-max=[longest cover edge in px]:px:' \
                        '--skip-cover[strip / skip cover art]' \
                        '--ascii-filenames[transliterate filenames to ASCII]'
                    ;;
                doctor)
                    _arguments \
                        '--profile=[profile to resolve and display]:profile:_ytmv_profiles' \
                        '--list-profiles[print known profile names, one per line]' \
                        '--offline[skip the LRCLIB reachability check]' \
                        '--json[emit JSON instead of a table]'
                    ;;
            esac
            ;;
    esac
}

compdef _ytmv ytmv
