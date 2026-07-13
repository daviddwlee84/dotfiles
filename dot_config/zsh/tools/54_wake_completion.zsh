# 54_wake_completion.zsh - tab completion for `wake` (Wake-on-LAN sender).
# Source CLI: dot_dotfiles/bin/executable_wake. Mirrors the bash twin
# 54_wake_completion.bash — keep both in sync. See docs/zsh/zsh-completions.md §F.
#
# Host names are completed dynamically from `wake --list-names` (which reads
# ~/.config/wake/hosts.toml), same pattern as `_fleet_hosts_one`.

(( $+commands[wake] )) || return 0

_wake() {
    local -a hosts
    hosts=(${(f)"$(wake --list-names 2>/dev/null)"})
    _arguments -s \
        '(-l --list)'{-l,--list}'[list configured hosts]' \
        '--list-names[print bare host names]' \
        '(-b --broadcast)'{-b,--broadcast}'[broadcast address]:addr:' \
        '(-p --port)'{-p,--port}'[UDP port]:port:' \
        '(-c --count)'{-c,--count}'[packets per target]:count:' \
        '(-q --quiet)'{-q,--quiet}'[suppress per-packet output]' \
        '*:host or MAC:->targets'
    if [[ $state == targets ]]; then
        _describe -t hosts 'wake host' hosts
    fi
}

compdef _wake wake
