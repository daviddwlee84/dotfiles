# Shared backend for editorcfg and dotfiles-editor. POSIX sh; no shell eval.
# Config is one preset per file, never a command string.

editorcfg_valid() {
    case $1 in nvim|micro|vim|nano|code|cursor) return 0 ;; *) return 1 ;; esac
}

editorcfg_paths() {
    editorcfg_dir=${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles
    editorcfg_default=$editorcfg_dir/editor-default
    editorcfg_local=$editorcfg_dir/editor-choice
}

editorcfg_preference() {
    editorcfg_paths
    editorcfg_source=legacy-default
    editorcfg_preferred=nvim
    if [ -e "$editorcfg_local" ] || [ -L "$editorcfg_local" ]; then
        editorcfg_source=$editorcfg_local
    elif [ -e "$editorcfg_default" ]; then
        editorcfg_source=$editorcfg_default
    fi
    if [ "$editorcfg_source" != legacy-default ]; then
        editorcfg_preferred=$(cat "$editorcfg_source") || return 2
    fi
    if ! editorcfg_valid "$editorcfg_preferred"; then
        printf 'editorcfg: invalid preset in %s; use editorcfg use PRESET or reset\n' "$editorcfg_source" >&2
        return 2
    fi
}

editorcfg_find() {
    editorcfg_executable=$(command -v "$1" 2>/dev/null) || return 1
    [ -f "$editorcfg_executable" ] && [ -x "$editorcfg_executable" ]
}

editorcfg_resolve() {
    editorcfg_preference || return $?
    editorcfg_candidates="$editorcfg_preferred micro nano"
    case $editorcfg_preferred in nvim|vim) editorcfg_candidates="$editorcfg_candidates nvim vim vi" ;; esac
    editorcfg_seen=' '
    for editorcfg_candidate in $editorcfg_candidates; do
        case $editorcfg_seen in *" $editorcfg_candidate "*) continue ;; esac
        editorcfg_seen="$editorcfg_seen$editorcfg_candidate "
        if editorcfg_find "$editorcfg_candidate"; then
            editorcfg_selected=$editorcfg_candidate
            return 0
        fi
    done
    printf 'editorcfg: no usable editor for %s; install micro (brew install micro / apt install micro), then retry\n' "$editorcfg_preferred" >&2
    return 127
}

editorcfg_launch() {
    editorcfg_resolve || return $?
    if [ "$editorcfg_selected" != "$editorcfg_preferred" ]; then
        printf 'dotfiles-editor: %s unavailable; using %s (%s)\n' "$editorcfg_preferred" "$editorcfg_selected" "$editorcfg_executable" >&2
    fi
    # Exec preserves the terminal, cwd, wait semantics and the actual exit code.
    case $editorcfg_selected in
        code|cursor) exec "$editorcfg_executable" --wait "$@" ;;
        *) exec "$editorcfg_executable" "$@" ;;
    esac
}

editorcfg_overrides() {
    for editorcfg_var in EDITOR VISUAL; do
        case $editorcfg_var in EDITOR) editorcfg_value=${EDITOR:-} ;; VISUAL) editorcfg_value=${VISUAL:-} ;; esac
        printf '%s: %s\n' "$editorcfg_var" "${editorcfg_value:-(unset)}"
        if [ "$editorcfg_value" != dotfiles-editor ]; then
            printf '  overrides/bypasses managed selection; reload the profile or check your adhoc file\n'
        fi
    done
    if command -v git >/dev/null 2>&1; then
        printf 'Git effective editor: '
        git var GIT_EDITOR 2>/dev/null || printf '(unavailable)\n'
        git config --show-origin --get core.editor || :
        if [ -n "${GIT_EDITOR:-}" ]; then printf 'GIT_EDITOR override: %s\n' "$GIT_EDITOR"; fi
    fi
}

editorcfg_main() {
    editorcfg_paths
    editorcfg_action=${1:-status}
    [ "$#" -eq 0 ] || shift
    case $editorcfg_action in
        use)
            if [ "$#" -ne 1 ] || ! editorcfg_valid "$1"; then
                printf 'usage: editorcfg use {nvim|micro|vim|nano|code|cursor}\n' >&2
                return 2
            fi
            if ! editorcfg_find "$1"; then
                printf 'editorcfg: %s is not installed/on PATH; preference unchanged\n' "$1" >&2
                return 127
            fi
            # Only this tool's dedicated preference is written, never shell rc.
            (
                umask 077
                mkdir -p "$editorcfg_dir" || exit 1
                editorcfg_tmp=$(mktemp "$editorcfg_dir/.editor-choice.XXXXXX") || exit 1
                trap 'rm -f "$editorcfg_tmp"' EXIT
                trap 'exit 130' INT
                trap 'exit 143' TERM
                printf '%s\n' "$1" > "$editorcfg_tmp" && mv -f "$editorcfg_tmp" "$editorcfg_local"
            ) || return $?
            printf 'Preferred editor: %s (next managed launch; no apply needed)\n' "$1"
            editorcfg_overrides
            ;;
        reset)
            [ "$#" -eq 0 ] || return 2
            # Reset only our single-purpose override; never remove a directory.
            if [ -d "$editorcfg_local" ]; then
                printf 'editorcfg: refusing to remove directory %s\n' "$editorcfg_local" >&2
                return 2
            fi
            rm -f "$editorcfg_local" || return $?
            editorcfg_preference || return $?
            printf 'Restored init preference: %s\n' "$editorcfg_preferred"
            ;;
        list)
            [ "$#" -eq 0 ] || return 2
            for editorcfg_preset in nvim micro vim nano code cursor; do
                if editorcfg_find "$editorcfg_preset"; then
                    printf '%s\t%s\n' "$editorcfg_preset" "$editorcfg_executable"
                else
                    printf '%s\t(not installed)\n' "$editorcfg_preset"
                fi
            done
            ;;
        status|doctor)
            [ "$#" -eq 0 ] || return 2
            editorcfg_rc=0
            editorcfg_resolve || editorcfg_rc=$?
            printf 'Preferred: %s\nSource: %s\n' "$editorcfg_preferred" "$editorcfg_source"
            if [ "$editorcfg_rc" -eq 0 ]; then
                printf 'Resolved: %s (%s)\n' "$editorcfg_selected" "$editorcfg_executable"
            fi
            editorcfg_overrides
            if [ "$editorcfg_action" = doctor ]; then
                if editorcfg_find dotfiles-editor; then
                    printf 'Launcher: %s\n' "$editorcfg_executable"
                else
                    printf 'Launcher missing on PATH; apply dotfiles and reload your profile\n' >&2
                    editorcfg_rc=127
                fi
                printf 'Availability only: GUI wait, terminal input and IME require an interactive smoke test.\n'
            fi
            return "$editorcfg_rc"
            ;;
        help|--help|-h)
            printf 'editorcfg [status|list|doctor|use PRESET|reset]\nPresets: nvim micro vim nano code cursor\n'
            ;;
        *) printf 'editorcfg: unknown command %s (see --help)\n' "$editorcfg_action" >&2; return 2 ;;
    esac
}
