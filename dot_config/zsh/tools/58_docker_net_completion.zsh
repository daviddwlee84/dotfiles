# 58_docker_net_completion.zsh - tab completion for `docker-net`.
# Source: dot_config/shell/51_docker_net.sh (a shell FUNCTION family, not a
# binary in dot_dotfiles/bin/ — hence `command -v` rather than `$+commands`,
# which only sees external commands).
#
# Loaded eagerly by load_modular_dir AFTER compinit, and after
# $XDG_CONFIG_HOME/shell (dot_zshrc.tmpl sources shell/ at :138, zsh/tools/ at
# :140), so both `compdef` and the guard below are safe.
#
# Keep in sync with dot_config/bash/58_docker_net_completion.bash and with the
# verb list in `_dnet_usage`.

command -v docker-net >/dev/null 2>&1 || return 0

_docker_net() {
    local -a verbs
    verbs=(
        'status:install shape, daemon proxy, mirrors, detected local proxy'
        'doctor:full layer-by-layer diagnosis'
        'on:write daemon.json `proxies` and restart the daemon'
        'off:remove it and restart'
        'mirrors:mirror health only (fast)'
        'pull:pull with a mirror/skopeo fallback ladder'
        'help:usage'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'docker-net action' verbs
        return
    fi

    case "${words[2]}" in
        doctor)
            _arguments '--deep[also probe ghcr/gcr/quay/registry.k8s.io from the daemon side]'
            ;;
        on)
            # A proxy URL is positional; -y skips the kill-my-containers prompt.
            _arguments \
                '-y[skip the running-container confirmation]' \
                '--yes[skip the running-container confirmation]' \
                '*:proxy URL:_urls'
            ;;
        off)
            _arguments '-y[skip the running-container confirmation]' '--yes[skip the running-container confirmation]'
            ;;
        pull)
            # Offer locally-known images as a hint; any registry ref is valid.
            local -a images
            images=(${(f)"$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>')"})
            (( ${#images} )) && _describe -t images 'local image' images
            ;;
    esac
}

compdef _docker_net docker-net
