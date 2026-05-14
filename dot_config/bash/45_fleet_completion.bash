# 45_fleet_completion.bash - tab completion for `fleet` (umbrella CLI).
# Source CLI: dot_dotfiles/bin/executable_fleet (hand-rolled dispatcher).
# Mirrors dot_config/zsh/tools/45_fleet_completion.zsh — keep both in sync
# when adding subcommands or flags.

command -v fleet >/dev/null 2>&1 || return 0

# Dynamic helpers ------------------------------------------------------------

_fleet_hosts_one() {
    local cur="$1"
    local hosts
    hosts=$(fleet hosts --list 2>/dev/null)
    COMPREPLY=( $(compgen -W "$hosts" -- "$cur") )
}

# CSV completion: complete the rightmost segment of `--hosts=a,b,<TAB>`.
# Falls back gracefully on bash < 4.x where `${cur##*,}` still works.
_fleet_hosts_csv() {
    local cur="$1"
    local hosts existing tail matches
    hosts=$(fleet hosts --list 2>/dev/null)
    if [[ "$cur" == *,* ]]; then
        existing="${cur%,*},"
        tail="${cur##*,}"
    else
        existing=""
        tail="$cur"
    fi
    matches=$(compgen -W "$hosts" -- "$tail")
    COMPREPLY=()
    local m
    while IFS= read -r m; do
        [ -n "$m" ] && COMPREPLY+=( "${existing}${m}" )
    done <<< "$matches"
}

# Subcommand completions -----------------------------------------------------

_fleet_chezmoi() {
    local cur prev words cword
    cur="$1"; prev="$2"; words=("${!3}"); cword="$4"

    # words[2] is the action name (apply/status/...)
    if [ "$cword" -eq 2 ]; then
        COMPREPLY=( $(compgen -W "apply status diff tail kill compact" -- "$cur") )
        return
    fi

    local action="${words[2]}"
    case "$action" in
        apply)
            case "$prev" in
                --hosts) _fleet_hosts_csv "$cur"; return ;;
                --branch|--watch) return ;;
            esac
            COMPREPLY=( $(compgen -W "--hosts --dry-run --force --serial --branch --readiness --readiness-no-fetch --readiness-json --status --watch" -- "$cur") )
            ;;
        status)
            case "$prev" in
                --watch) return ;;
            esac
            COMPREPLY=( $(compgen -W "--quick --live --watch" -- "$cur") )
            ;;
        diff|tail)
            _fleet_hosts_one "$cur"
            ;;
        kill)
            case "$prev" in
                --hosts) _fleet_hosts_csv "$cur"; return ;;
            esac
            COMPREPLY=( $(compgen -W "--hosts" -- "$cur") )
            ;;
        compact)
            case "$prev" in
                --run-id) return ;;
            esac
            COMPREPLY=( $(compgen -W "--run-id" -- "$cur") )
            ;;
    esac
}

# Top-level dispatcher -------------------------------------------------------

_fleet_completion() {
    local cur prev words cword
    _init_completion -n = || return

    if [ "$cword" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "chezmoi edit tmux info pueue exec hosts" -- "$cur") )
        return
    fi

    local sub="${words[1]}"

    if [ "$sub" = "chezmoi" ]; then
        _fleet_chezmoi "$cur" "$prev" "words[@]" "$cword"
        return
    fi

    case "$sub" in
        tmux)
            case "$prev" in
                --hosts) _fleet_hosts_csv "$cur"; return ;;
            esac
            COMPREPLY=( $(compgen -W "--hosts --json --deep" -- "$cur") )
            ;;
        info)
            case "$prev" in
                --hosts) _fleet_hosts_csv "$cur"; return ;;
                --modules) return ;;
            esac
            COMPREPLY=( $(compgen -W "--hosts --ff --full --modules --json" -- "$cur") )
            ;;
        pueue)
            case "$prev" in
                --hosts) _fleet_hosts_csv "$cur"; return ;;
                --group) return ;;
                --out) _filedir; return ;;
            esac
            COMPREPLY=( $(compgen -W "--hosts --group --json --ai --report --out" -- "$cur") )
            ;;
        exec)
            case "$prev" in
                --hosts) _fleet_hosts_csv "$cur"; return ;;
                --shell) COMPREPLY=( $(compgen -W "bash zsh sh" -- "$cur") ); return ;;
                --out-dir) _filedir -d; return ;;
            esac
            COMPREPLY=( $(compgen -W "--hosts --shell --login --json --out-dir --ai --" -- "$cur") )
            ;;
        hosts)
            case "$prev" in
                --describe|--probe) _fleet_hosts_one "$cur"; return ;;
                --config) _filedir; return ;;
            esac
            case "$cur" in
                -*)
                    COMPREPLY=( $(compgen -W "--list --list-tsv --list-json --describe --probe --include-local --config" -- "$cur") )
                    ;;
                *)
                    _fleet_hosts_one "$cur"
                    ;;
            esac
            ;;
    esac
}

complete -F _fleet_completion fleet
