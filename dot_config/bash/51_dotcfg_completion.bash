# 51_dotcfg_completion.bash - tab completion for `dotcfg` (reconfigure wrapper).
# Source CLI: dot_dotfiles/bin/executable_dotcfg → scripts/init/dotfiles_init.py
# reconfigure. Loaded by load_modular_dir AFTER 03_completion.bash
# (bash-completion v2), so `_init_completion` is available.
# Keep the key list in sync with the zsh sibling (51_dotcfg_completion.zsh).

command -v dotcfg >/dev/null 2>&1 || return 0

_dotcfg_completion() {
    local cur prev words cword
    _init_completion || return

    local flags="--set --yes --dry-run --no-apply --help"
    local keys="profile email name \
installCodingAgents installLlmTools installAiDesktopApps \
installPythonUvTools installJsCliTools installDotnetTools installAuditd \
installIacTools installMediaTools installBitwarden installBrewApps \
installInputMethod discordChannel installNetworkingTools installTunnelTools \
useChineseMirror gitleaksAllRepos backupMode allowPartialFailure noRoot \
motdStyle primaryShell enableVimMode"

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        return
    fi

    local w
    for w in "${words[@]}"; do
        if [ "$w" = "--set" ]; then
            COMPREPLY=( $(compgen -W "$keys" -- "$cur") )
            compopt -o nospace 2>/dev/null
            local i
            for i in "${!COMPREPLY[@]}"; do COMPREPLY[$i]="${COMPREPLY[$i]}="; done
            return
        fi
    done
    COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
}

complete -F _dotcfg_completion dotcfg
