# 33_mole.sh - mole helpers (shared by zsh/bash)
# https://github.com/tw93/Mole  —  docs/tools/mole.md
#
# mole is macOS-only upstream (install.sh refuses non-darwin, cmd/analyze is
# //go:build darwin), so on Linux this fragment is a no-op via the guard below.
# `mo` is mole's own short entrypoint — do not alias over it.

command -v mole >/dev/null 2>&1 || return 0

MOLE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mole"

# `mo analyze` with no argument explores $HOME. Scope it to a directory instead
# (default: cwd) — the common case is "why is this checkout so big".
moa() {
    mo analyze "${1:-$PWD}"
}

# `mo clean` deletes without asking first; only --dry-run shows the plan. Always
# preview, then confirm. Any extra args are passed through to both passes.
moclean() {
    printf '\033[0;34m==> mo clean --dry-run\033[0m\n'
    mo clean --dry-run "$@" || return $?
    printf '\nProceed with the real clean? [y/N] '
    local reply=''
    read -r reply || return 1
    case "$reply" in
        [yY] | [yY][eE][sS]) mo clean "$@" ;;
        *) printf 'Aborted.\n' ;;
    esac
}

# Show what the managed seeds currently protect, and how to re-baseline them.
# Both files are chezmoi `create_` seeds: mole rewrites them itself through
# `mo clean --whitelist` / `mo purge --paths`, so chezmoi deliberately never
# updates them after the first apply.
mowl() {
    local f
    for f in "$MOLE_CONFIG_DIR/whitelist" "$MOLE_CONFIG_DIR/purge_paths"; do
        printf '\033[0;34m==> %s\033[0m\n' "$f"
        if [ -f "$f" ]; then
            grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$f" || true
        else
            printf '(missing — chezmoi apply seeds it when installMole=true)\n'
        fi
        printf '\n'
    done
    printf 'Edit:        mo clean --whitelist   /   mo purge --paths\n'
    # shellcheck disable=SC2016  # literal command text for the user to copy
    printf 'Re-baseline: cp <file> "$(chezmoi source-path <file>)"\n'
}
