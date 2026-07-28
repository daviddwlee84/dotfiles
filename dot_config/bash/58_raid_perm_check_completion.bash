# 58_raid_perm_check_completion.bash - tab completion for `raid-perm-check`.
# Source CLI: dot_dotfiles/bin/executable_raid-perm-check (bash hand-rolled,
# subcommands summary/orphans/groups/units/user/all).
# Mirrors dot_config/zsh/tools/58_raid_perm_check_completion.zsh — keep both in sync.

command -v raid-perm-check >/dev/null 2>&1 || return 0

# Dynamic helper: real login accounts (uid >= 1000, excluding nobody).
_raid_perm_check_users() {
    getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3<65534 {print $1}'
}

# Mount roots worth auditing, minus the kernel pseudo-filesystems.
_raid_perm_check_roots() {
    findmnt -rno TARGET 2>/dev/null | grep -vE '^/(proc|sys|dev|run)'
}

_raid_perm_check_completion() {
    local cur prev words cword
    _init_completion || return

    local subcmds="summary orphans groups units user all help"

    if [ "$cword" -eq 1 ]; then
        # subcommands + mount points (a bare dir routes to `summary`)
        COMPREPLY=( $(compgen -W "$subcmds $(_raid_perm_check_roots)" -- "$cur") )
        compopt -o dirnames 2>/dev/null
        return
    fi

    local sub="${words[1]}"
    case "$sub" in
        user)
            if [ "$cword" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$(_raid_perm_check_users)" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "$(_raid_perm_check_roots)" -- "$cur") )
                compopt -o dirnames 2>/dev/null
            fi
            ;;
        units|help)
            COMPREPLY=()
            ;;
        summary|orphans|groups|all)
            COMPREPLY=( $(compgen -W "$(_raid_perm_check_roots)" -- "$cur") )
            compopt -o dirnames 2>/dev/null
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

complete -F _raid_perm_check_completion raid-perm-check
