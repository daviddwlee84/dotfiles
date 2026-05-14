# 45_fleet_completion.zsh - tab completion for `fleet` (fleet-apply umbrella).
# Source CLI: dot_dotfiles/bin/executable_fleet (hand-rolled dispatcher) +
# scripts/fleet/{apply,tmux,info,pueue,exec,hosts}.py (tyro + argparse mix).
# Dynamic host names via `fleet hosts --list`.
#
# Layout per the umbrella USAGE string:
#   fleet chezmoi {apply,status,diff,tail,kill,compact} [...]
#   fleet {edit,tmux,info,pueue,exec,hosts} [...]

(( $+commands[fleet] )) || return 0

# Dynamic helpers ------------------------------------------------------------

_fleet_hosts_one() {
    local -a hosts
    hosts=( ${(f)"$(fleet hosts --list 2>/dev/null)"} )
    (( ${#hosts} )) && _describe -t hosts 'fleet host' hosts
}

_fleet_hosts_csv() {
    local -a hosts
    hosts=( ${(f)"$(fleet hosts --list 2>/dev/null)"} )
    (( ${#hosts} )) && _values -s , 'fleet host' $hosts
}

# Subcommand completions -----------------------------------------------------

_fleet_chezmoi_apply() {
    _arguments \
        '--hosts=[comma-separated host names]:hosts:_fleet_hosts_csv' \
        '--dry-run[show what would change without applying]' \
        '--force[overwrite remote drift]' \
        '--serial[run hosts sequentially]' \
        '--branch=[git branch to apply (no-op on local hosts)]:branch:' \
        '--readiness[pre-flight readiness probe]' \
        '--readiness-no-fetch[skip remote git fetch]' \
        '--readiness-json[JSON output for readiness]' \
        '--status[process-liveness probe]' \
        '--watch=[poll every N seconds (with --status)]:seconds:'
}

_fleet_chezmoi_status() {
    _arguments \
        '--quick[skip remote git fetch (faster)]' \
        '--live[process-liveness probe (use during/after apply)]' \
        '--watch=[poll every N seconds (with --live)]:seconds:'
}

_fleet_chezmoi() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->action' \
        '*::action_arg:->action_args'

    case "$state" in
        action)
            local -a actions=(
                'apply:Run chezmoi update --init across the fleet'
                'status:Pre-flight readiness probe (--quick / --live for variants)'
                'diff:chezmoi diff on one host (--dry-run --hosts HOST --serial)'
                'tail:Live-tail a remote fleet-apply log (positional HOST[:RUN_ID])'
                'kill:pkill chezmoi/ansible across the fleet'
                'compact:Post-mortem summary'
            )
            _describe -t chezmoi-actions 'fleet chezmoi action' actions
            ;;
        action_args)
            case "$line[1]" in
                apply)   _fleet_chezmoi_apply ;;
                status)  _fleet_chezmoi_status ;;
                diff|tail) _fleet_hosts_one ;;
                kill)    _arguments '--hosts=[comma-separated host names]:hosts:_fleet_hosts_csv' ;;
                compact) _arguments '--run-id=[specific apply run id]:run-id:' ;;
            esac
            ;;
    esac
}

_fleet_tmux() {
    _arguments \
        '--hosts=[comma-separated host names]:hosts:_fleet_hosts_csv' \
        '--json[emit JSON]' \
        '--deep[include visible pane area (slower)]'
}

_fleet_info() {
    _arguments \
        '--hosts=[comma-separated host names]:hosts:_fleet_hosts_csv' \
        '--ff[fast-fail mode]' \
        '--full[full report]' \
        '--modules=[comma-separated module names]:modules:' \
        '--json[emit JSON]'
}

_fleet_pueue() {
    _arguments \
        '--hosts=[comma-separated host names]:hosts:_fleet_hosts_csv' \
        '--group=[restrict to one pueue group]:group:' \
        '--json[emit JSON]' \
        '--ai[AI summary via pqsum]' \
        '--report[markdown report (with --ai)]' \
        '--out=[write report to PATH]:path:_files'
}

_fleet_exec() {
    _arguments \
        '--hosts=[comma-separated host names]:hosts:_fleet_hosts_csv' \
        '--shell=[opt-in shell expansion]:shell:(bash zsh sh)' \
        '--login[full rc-loaded env]' \
        '--json[emit JSON]' \
        '--out-dir=[write per-host output to DIR]:dir:_directories' \
        '--ai[succeeded/differed/failed classification]' \
        '*::cmd: _normal'
}

_fleet_hosts() {
    _arguments \
        '--list[plain host names, one per line]' \
        '--list-tsv[TSV name<TAB>target<TAB>kind (used by tv cable source)]' \
        '--list-json[full inventory as JSON]' \
        '--describe=[print preview block for NAME]:host:_fleet_hosts_one' \
        '--probe=[BatchMode SSH probe of NAME]:host:_fleet_hosts_one' \
        '--include-local[include local hosts in --list-tsv]' \
        '--config=[fleet inventory path]:path:_files' \
        ':host:_fleet_hosts_one'
}

# Top-level dispatcher -------------------------------------------------------

_fleet() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*::arg:->args'

    case "$state" in
        subcommand)
            local -a subs=(
                'chezmoi:Chezmoi-specific deploy ops (apply/status/diff/tail/kill/compact)'
                'edit:Open ~/.config/fleet/machines.toml in $EDITOR'
                'tmux:Cross-host tmux session summary'
                'info:Cross-host system status snapshot'
                'pueue:Cross-host pueue queue summary'
                'exec:Cross-host ad-hoc command runner (use -- to separate CMD)'
                'hosts:Pick a fleet-configured host and SSH in (or list inventory)'
            )
            _describe -t subcommands 'fleet subcommand' subs
            ;;
        args)
            case "$line[1]" in
                chezmoi) _fleet_chezmoi ;;
                tmux)    _fleet_tmux ;;
                info)    _fleet_info ;;
                pueue)   _fleet_pueue ;;
                exec)    _fleet_exec ;;
                hosts)   _fleet_hosts ;;
                edit)    ;;  # no args
            esac
            ;;
    esac
}

compdef _fleet fleet
