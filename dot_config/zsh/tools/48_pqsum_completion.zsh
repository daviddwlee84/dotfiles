# 48_pqsum_completion.zsh - tab completion for `pqsum` (pueue queue summary).
# Source CLI: dot_dotfiles/bin/executable_pqsum (argparse, positional mode +
# many flags). Dynamic group completion via `pueue status --json | jq`.

(( $+commands[pqsum] )) || return 0

_pqsum() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '(- *)'{-h,--help}'[show help]' \
        '(-g --group)'{-g,--group}'=[restrict to one pueue group]:group:->group' \
        '--report[emit markdown report (ai mode only)]' \
        '--out=[write report to PATH]:path:_files' \
        '--clean[execute cleanup commands on safe-to-clean groups]' \
        '--yes[skip y/N prompts (with --clean)]' \
        '--multi-host[tell LLM the input describes multiple hosts]' \
        '--stdin-json[read pre-merged host snapshots from stdin]' \
        '--raw-stdin[read raw `pueue status --json` from stdin]' \
        '--host=[override host name when --raw-stdin is set]:hostname:_hosts' \
        '--deep[include extra recovery context (last ~20 log lines per failed task)]' \
        '(-r --refresh)'{-r,--refresh}'[bypass prompt-hash cache]' \
        '--no-cache[do not read or write the cache]' \
        '--dry-run[print AI prompt; no AI call]' \
        '1:mode:(text ai json)'

    case "$state" in
        group)
            local -a groups
            if (( $+commands[pueue] )) && (( $+commands[jq] )); then
                groups=( ${(f)"$(pueue status --json 2>/dev/null | jq -r '.groups | keys[]' 2>/dev/null)"} )
                (( ${#groups} )) && _describe 'pueue group' groups
            fi
            ;;
    esac
}

compdef _pqsum pqsum
