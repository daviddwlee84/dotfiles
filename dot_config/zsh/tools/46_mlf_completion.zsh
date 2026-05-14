# 46_mlf_completion.zsh - tab completion for `mlf` (MLflow umbrella CLI).
# Source CLI: dot_dotfiles/bin/executable_mlf (hand-rolled dispatcher) +
# scripts/mlf/{plot,list,download}.py (tyro).
#
# Note: `<run_id>`, `<experiment>`, `<model_name>` are NOT auto-completed
# from MLflow because each lookup would round-trip the tracking server (slow,
# possibly auth-required). Use `tv mlflow` channel for fuzzy id picking.

(( $+commands[mlf] )) || return 0

_mlf_list() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->kind' \
        '*::kind_arg:->kind_args'

    case "$state" in
        kind)
            local -a kinds=(
                'experiments:List MLflow experiments'
                'runs:List runs (use --experiment to scope)'
                'models:List registered models'
            )
            _describe -t list-kinds 'mlf list kind' kinds
            ;;
        kind_args)
            case "$line[1]" in
                runs)
                    _arguments \
                        '--experiment=[experiment id]:experiment-id:' \
                        '--limit=[max rows]:N:' \
                        '--json[emit JSON to stdout]'
                    ;;
                experiments|models)
                    _arguments \
                        '--limit=[max rows]:N:' \
                        '--json[emit JSON to stdout]'
                    ;;
            esac
            ;;
    esac
}

_mlf_plot() {
    _arguments \
        '1:run-id:' \
        '*:metric:' \
        '--width=[plot width in chars]:width:' \
        '--height=[plot height in chars]:height:' \
        '--theme=[plotext theme name]:theme:'
}

_mlf_download() {
    _arguments \
        '1:model:' \
        '--dest=[output directory]:dir:_directories'
}

_mlf() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*::arg:->args'

    case "$state" in
        subcommand)
            local -a subs=(
                'tui:Launch the interactive Textual dashboard (default if no args)'
                'tv:Launch tv mlflow fuzzy picker (passes argv + env through)'
                'open:Open experiment / run / model page in browser'
                'copy:Copy id to clipboard'
                'plot:Terminal line plot of metric history'
                'list:Tabular dump of experiments / runs / models'
                'download:Download a registered model'\''s artifacts'
            )
            _describe -t subcommands 'mlf subcommand' subs
            ;;
        args)
            case "$line[1]" in
                list)     _mlf_list ;;
                plot)     _mlf_plot ;;
                download) _mlf_download ;;
                open|copy) _arguments '1:id:' ;;  # opaque id, can't enumerate
                tv)       _arguments '*:tv-arg:' ;;  # passthrough to tv
                tui)      ;;  # no args
            esac
            ;;
    esac
}

compdef _mlf mlf
