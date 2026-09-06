# 51_dotcfg_completion.zsh - tab completion for `dotcfg` (reconfigure wrapper).
# Source CLI: dot_dotfiles/bin/executable_dotcfg → scripts/init/dotfiles_init.py
# reconfigure. Loaded eagerly by load_modular_dir AFTER compinit in
# dot_zshrc.tmpl, so `compdef _dotcfg dotcfg` is safe.
#
# Keys mirror the PROMPTS table in scripts/init/dotfiles_init.py. They drift at
# worst into a stale completion hint (never a runtime error — the script
# validates --set keys), so we keep them inline rather than shelling out.

(( $+commands[dotcfg] )) || return 0

_dotcfg_keys=(
    profile email name
    installCodingAgents installLlmTools installAiDesktopApps
    installPythonUvTools installJsCliTools installDotnetTools installAuditd
    installIacTools installMediaTools installBitwarden installBrewApps
    installGamingApps installInputMethod discordChannel installNetworkingTools installTunnelTools
    useChineseMirror gitleaksAllRepos backupMode allowPartialFailure noRoot
    motdStyle primaryShell preferredEditor enableVimMode
)

_dotcfg() {
    local cur="${words[CURRENT]}"
    if [[ "$cur" == -* ]]; then
        compadd -- --set --yes --dry-run --no-apply --help
        return
    fi
    # Inside a `--set key=value …` list → offer prompt keys with a trailing '='.
    if (( ${words[(I)--set]} )); then
        compadd -S '=' -- "${_dotcfg_keys[@]}"
        return
    fi
    compadd -- --set --yes --dry-run --no-apply --help
}

compdef _dotcfg dotcfg
