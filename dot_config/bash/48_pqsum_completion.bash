# 48_pqsum_completion.bash - tab completion for `pqsum` (pueue queue summary).
# Source CLI: dot_dotfiles/bin/executable_pqsum (argparse).
# Dynamic group completion via `pueue status --json | jq`.

command -v pqsum >/dev/null 2>&1 || return 0

_pqsum_completion() {
    local cur prev words cword
    _init_completion -n = || return

    case "$prev" in
        -g|--group)
            if command -v pueue >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
                local groups
                groups=$(pueue status --json 2>/dev/null | jq -r '.groups | keys[]' 2>/dev/null)
                COMPREPLY=( $(compgen -W "$groups" -- "$cur") )
            fi
            return
            ;;
        --out)
            _filedir
            return
            ;;
        --host)
            return
            ;;
    esac

    case "$cur" in
        -*)
            local opts="-h --help -g --group --report --out --clean --yes --multi-host --stdin-json --raw-stdin --host --deep -r --refresh --no-cache --dry-run"
            COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            ;;
        *)
            # Only one positional (mode) — count non-flag words so far.
            local i pos=0
            for ((i = 1; i < cword; i++)); do
                case "${words[i]}" in
                    -*) ;;
                    *) ((pos++)) ;;
                esac
            done
            if [ "$pos" -eq 0 ]; then
                COMPREPLY=( $(compgen -W "text ai json" -- "$cur") )
            fi
            ;;
    esac
}

complete -F _pqsum_completion pqsum
