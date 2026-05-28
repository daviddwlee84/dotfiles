# 50_ping_monitor_completion.bash - tab completion for `ping-monitor`.
# Source CLI: dot_dotfiles/bin/executable_ping-monitor.
# Loaded by load_modular_dir AFTER 03_completion.bash (bash-completion v2),
# so `_init_completion` is available. Keep in sync with the zsh version.

command -v ping-monitor >/dev/null 2>&1 || return 0

_ping_monitor_completion() {
    local cur prev words cword
    _init_completion || return

    if [ "$cword" -eq 1 ]; then
        case "$cur" in
            -*) COMPREPLY=( $(compgen -W "-g --gateway -h --help" -- "$cur") ) ;;
            *)  COMPREPLY=( $(compgen -A hostname -- "$cur") ) ;;
        esac
        return
    fi
}

complete -F _ping_monitor_completion ping-monitor
