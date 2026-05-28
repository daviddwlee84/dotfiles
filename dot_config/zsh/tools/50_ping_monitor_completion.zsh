# 50_ping_monitor_completion.zsh - tab completion for `ping-monitor`.
# Source CLI: dot_dotfiles/bin/executable_ping-monitor (bash script:
# positional [TARGET] [SPIKE_MS] [INTERVAL_S], plus -g/--gateway, -h/--help).
# Loaded eagerly by load_modular_dir AFTER compinit in dot_zshrc.tmpl, so
# `compdef` is safe. Keep in sync with dot_config/bash/50_ping_monitor_completion.bash.

(( $+commands[ping-monitor] )) || return 0

_ping_monitor() {
    _arguments \
        '(-g --gateway)'{-g,--gateway}'[ping the default gateway]' \
        '(-h --help)'{-h,--help}'[show help]' \
        '1:target host:_hosts' \
        '2:spike threshold (ms):' \
        '3:interval (s):'
}

compdef _ping_monitor ping-monitor
