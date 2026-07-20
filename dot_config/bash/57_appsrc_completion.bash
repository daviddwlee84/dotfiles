# 57_appsrc_completion.bash - tab completion for `appsrc` (install-source detector).
# Source CLI: dot_dotfiles/bin/executable_appsrc (argparse, subcommands scan/which).
# Mirrors dot_config/zsh/tools/57_appsrc_completion.zsh — keep both in sync.

command -v appsrc >/dev/null 2>&1 || return 0

# Dynamic helper: GUI app names (from the CLI) + commands, for `which <name>`.
_appsrc_names() {
    local cur="$1" apps
    apps=$(appsrc scan --list-names 2>/dev/null)
    COMPREPLY=( $(compgen -W "$apps" -- "$cur") $(compgen -c -- "$cur") )
}

_appsrc_completion() {
    local cur prev words cword
    _init_completion -n = || return

    if [ "$cword" -eq 1 ]; then
        # subcommands + app names (bare word routes to `which`)
        local apps
        apps=$(appsrc scan --list-names 2>/dev/null)
        COMPREPLY=( $(compgen -W "scan which $apps" -- "$cur") )
        return
    fi

    local sub="${words[1]}"
    case "$sub" in
        scan)
            case "$prev" in
                --kind)
                    COMPREPLY=( $(compgen -W "gui cli all" -- "$cur") ); return ;;
                --source)
                    COMPREPLY=( $(compgen -W "homebrew-cask homebrew-formula mac-app-store direct-download-pkg direct-download-dmg manual macos-system apt snap flatpak appimage linuxbrew cargo npm pipx uv mise go gem" -- "$cur") ); return ;;
            esac
            COMPREPLY=( $(compgen -W "--json --kind --source -r --refresh --no-cache" -- "$cur") )
            ;;
        which|*)
            case "$prev" in
                --path) _filedir; return ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=( $(compgen -W "--json --path" -- "$cur") )
            else
                _appsrc_names "$cur"
            fi
            ;;
    esac
}

complete -F _appsrc_completion appsrc
