# 58_raid_perm_check_completion.zsh - tab completion for `raid-perm-check`.
# Source CLI: dot_dotfiles/bin/executable_raid-perm-check (bash hand-rolled,
# subcommands summary/orphans/groups/units/user/all).
# Mirrors dot_config/bash/58_raid_perm_check_completion.bash — keep both in sync.

(( $+commands[raid-perm-check] )) || return 0

# Dynamic helper: real login accounts (uid >= 1000, excluding nobody), for
# `raid-perm-check user <name>`. Same shell-out pattern as _wake / _appsrc_names.
_raid_perm_check_users() {
    local -a users
    users=( ${(f)"$(getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3<65534 {print $1}')"} )
    (( ${#users} )) && _describe -t users 'user' users
}

# Mount roots worth auditing: anything currently mounted, plus plain dirs.
_raid_perm_check_roots() {
    local -a roots
    roots=( ${(f)"$(findmnt -rno TARGET 2>/dev/null | grep -vE '^/(proc|sys|dev|run)' )"} )
    (( ${#roots} )) && _describe -t roots 'mount point' roots
    _files -/
}

_raid_perm_check() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -C \
        '(-h --help help)'{-h,--help}'[show usage]' \
        '1: :->cmd' \
        '*:: :->args' && return 0

    case $state in
        cmd)
            local -a subcmds
            subcmds=(
                'summary:top-level dirs, ACLs, and your own access (default)'
                'orphans:files whose uid/gid has no passwd/group entry'
                'groups:who is in which data group (incl. read-only tiers)'
                'units:systemd --user manager group staleness'
                'user:what a given account can actually reach'
                'all:every check'
                'help:show usage'
            )
            _describe -t commands 'subcommand' subcmds
            # A bare directory is also valid: `raid-perm-check /mnt/other`
            _raid_perm_check_roots
            ;;
        args)
            case ${line[1]} in
                user)
                    if (( CURRENT == 2 )); then
                        _raid_perm_check_users
                    else
                        _raid_perm_check_roots
                    fi
                    ;;
                units|help)
                    ;;  # take no further arguments
                summary|orphans|groups|all)
                    _raid_perm_check_roots
                    ;;
            esac
            ;;
    esac
}

compdef _raid_perm_check raid-perm-check
