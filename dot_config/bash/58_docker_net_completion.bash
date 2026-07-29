# 58_docker_net_completion.bash - tab completion for `docker-net`.
# Sister file of dot_config/zsh/tools/58_docker_net_completion.zsh — keep the
# verb list in sync with it and with `_dnet_usage` in
# dot_config/shell/51_docker_net.sh.
#
# `docker-net` is a shell FUNCTION (from $XDG_CONFIG_HOME/shell/51_docker_net.sh),
# not a binary, so guard with `command -v` rather than a PATH test. dot_bashrc
# sources $XDG_CONFIG_HOME/shell before $BASH_CONFIG_DIR, so it is defined by now.
#
# bash 3.2 compatible on purpose: macOS still ships /bin/bash 3.2.57, so
# `mapfile` (bash 4.0+) is unavailable there. Use the repo's usual
# `COMPREPLY=( $(compgen …) )` form — see 49_x / 54_wake for the same shape.

command -v docker-net >/dev/null 2>&1 || return 0

_docker_net_complete() {
    local cur verbs
    cur="${COMP_WORDS[COMP_CWORD]}"
    verbs="status doctor on off mirrors pull help"

    if [ "$COMP_CWORD" -eq 1 ]; then
        # shellcheck disable=SC2207 # bash 3.2 has no mapfile; repo-wide convention.
        COMPREPLY=( $(compgen -W "$verbs" -- "$cur") )
        return
    fi

    case "${COMP_WORDS[1]}" in
        doctor)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--deep" -- "$cur") )
            ;;
        on | off)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "-y --yes" -- "$cur") )
            ;;
        pull)
            # Local images are only a hint — any registry reference is valid.
            if [ "$COMP_CWORD" -eq 2 ]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>')" -- "$cur") )
            fi
            ;;
        *) COMPREPLY=() ;;
    esac
}

complete -F _docker_net_complete docker-net
