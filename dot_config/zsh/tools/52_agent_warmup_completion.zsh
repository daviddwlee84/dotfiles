# 49_agent_warmup_completion.zsh - tab completion for `agent-warmup`.
# Source CLI: dot_dotfiles/bin/executable_agent-warmup (argparse, subcommands).
# Keep in sync with dot_config/bash/49_agent_warmup_completion.bash.

(( $+commands[agent-warmup] )) || return 0

_agent_warmup() {
    local context state state_descr line
    typeset -A opt_args

    local -a run_flags=(
        '--model[Claude model (default $AICAP_CLAUDE_MODEL or haiku)]:model:(haiku sonnet opus)'
        '--prompt[warmup prompt]:prompt:'
        '--timeout[reply wait seconds]:seconds:'
        '--verify[send /usage and capture the panel]'
    )

    _arguments -C \
        '(- *)'{-h,--help}'[show help]' \
        '1:command:->command' \
        '*::arg:->args'

    case "$state" in
        command)
            local -a cmds=(
                'run:spawn interactive claude and send the warmup prompt'
                'at:queue a one-shot run via pueue'
                'install:install a recurring launchd/systemd timer'
                'uninstall:remove the recurring timer'
                'status:show timer, pending one-shots, recent runs'
                'cancel:remove pending pueue one-shots'
                'verify:run --verify --keep (empirical experiment helper)'
            )
            _describe -t commands 'agent-warmup command' cmds
            ;;
        args)
            case "$line[1]" in
                run)
                    _arguments $run_flags '--keep[keep the tmux session afterwards]'
                    ;;
                at)
                    _arguments $run_flags \
                        '--at[absolute time for pueue --delay]:time:' \
                        '--delay[relative delay for pueue --delay, e.g. 8h]:delay:' \
                        '--dry-run[print the pueue command only]'
                    ;;
                install)
                    _arguments $run_flags \
                        '--daily[schedule]:schedule:(daily weekdays weekends)' \
                        '--time[HH:MM 24h]:time:'
                    ;;
                verify)
                    _arguments $run_flags
                    ;;
                status)
                    _arguments '--json[machine-readable output]'
                    ;;
            esac
            ;;
    esac
}

compdef _agent_warmup agent-warmup
