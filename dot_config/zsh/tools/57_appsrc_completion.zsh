# 57_appsrc_completion.zsh - tab completion for `appsrc` (install-source detector).
# Source CLI: dot_dotfiles/bin/executable_appsrc (argparse, subcommands scan/which).
# Mirrors dot_config/bash/57_appsrc_completion.bash — keep both in sync.

(( $+commands[appsrc] )) || return 0

# Dynamic helper: GUI app names (from the CLI itself) + regular commands, for
# `appsrc which <name>` and the bare-word `appsrc <name>` shortcut.
_appsrc_names() {
    local -a apps
    apps=( ${(f)"$(appsrc scan --list-names 2>/dev/null)"} )
    (( ${#apps} )) && _describe -t apps 'installed app' apps
    _command_names -e
}

_appsrc_scan() {
    _arguments \
        '--json[emit JSON instead of a table]' \
        '--tsv[emit TSV rows (name/source/path/kind/package[/size])]' \
        '--kind=[restrict inventory]:kind:(gui cli all)' \
        '--source=[filter by source id/label]:source:(homebrew-cask homebrew-formula mac-app-store direct-download-pkg direct-download-dmg manual macos-system apt snap flatpak appimage linuxbrew cargo npm pipx uv mise go gem)' \
        '--sort=[sort order (size => biggest first, implies --size)]:sort:(source name size)' \
        '(-r --refresh)'{-r,--refresh}'[recompute; ignore cache]' \
        '--no-cache[do not read or write cache]' \
        '--size[also compute each item bundle size (cached)]' \
        '--human[human-readable sizes in --tsv]'
}

_appsrc_which() {
    _arguments \
        '--json[emit JSON]' \
        '--path=[classify PATH directly]:path:_files' \
        '1:name:_appsrc_names'
}

_appsrc_size() {
    _arguments \
        '--json[emit JSON]' \
        '--path=[size PATH directly]:path:_files' \
        '1:name:_appsrc_names'
}

_appsrc_tui() {
    _arguments '--kind=[initial inventory]:kind:(gui cli all)'
}

_appsrc() {
    local context state state_descr line
    typeset -A opt_args

    _arguments -C \
        '1: :->subcommand' \
        '*::arg:->args'

    case "$state" in
        subcommand)
            local -a subs=(
                'scan:Batch-inventory installed apps + CLIs (cached)'
                'which:Single lookup (live): command or GUI app name'
                'size:Footprint + associated storage (cache/data/containers) for one app'
                'tui:Interactive dashboard — sort by size, filter, drill in'
            )
            _describe -t subcommands 'appsrc subcommand' subs
            _appsrc_names   # bare word routes to `which`
            ;;
        args)
            case "$line[1]" in
                scan)  _appsrc_scan ;;
                size)  _appsrc_size ;;
                tui)   _appsrc_tui ;;
                *)     _appsrc_which ;;   # `which` or a bare name
            esac
            ;;
    esac
}

compdef _appsrc appsrc
