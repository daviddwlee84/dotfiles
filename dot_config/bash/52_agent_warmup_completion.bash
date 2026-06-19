# 49_agent_warmup_completion.bash - tab completion for `agent-warmup`.
# Source CLI: dot_dotfiles/bin/executable_agent-warmup (argparse, subcommands).
# Keep in sync with dot_config/zsh/tools/49_agent_warmup_completion.zsh.

command -v agent-warmup >/dev/null 2>&1 || return 0

_agent_warmup_completion() {
    local cur prev words cword
    _init_completion || return

    local cmds="run at install uninstall status cancel verify"
    local run_flags="--model --prompt --timeout --verify"

    # Find the subcommand (first non-flag word after argv[0]).
    local i sub=""
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
            -*) ;;
            *) sub="${words[i]}"; break ;;
        esac
    done

    if [ -z "$sub" ]; then
        COMPREPLY=( $(compgen -W "$cmds -h --help" -- "$cur") )
        return
    fi

    case "$prev" in
        --model) COMPREPLY=( $(compgen -W "haiku sonnet opus" -- "$cur") ); return ;;
        --daily) COMPREPLY=( $(compgen -W "daily weekdays weekends" -- "$cur") ); return ;;
        --prompt|--timeout|--time|--at|--delay) return ;;
    esac

    local opts=""
    case "$sub" in
        run)    opts="$run_flags --keep" ;;
        at)     opts="$run_flags --at --delay --dry-run" ;;
        install) opts="$run_flags --daily --time" ;;
        verify) opts="$run_flags" ;;
        status) opts="--json" ;;
    esac
    [ -n "$opts" ] && COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}

complete -F _agent_warmup_completion agent-warmup
