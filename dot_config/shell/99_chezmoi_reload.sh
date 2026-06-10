# 99_chezmoi_reload.sh - post-`chezmoi apply` reload hint + cas/cau wrappers
#
# Pattern:
#   - .chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl touches the
#     sentinel ~/.cache/chezmoi/last-apply after every chezmoi apply.
#   - At shell init (here) we record this shell session's birth time as a
#     temp marker file.
#   - On every prompt a precmd / PROMPT_COMMAND hook calls _chezmoi_reload_check.
#   - Check fires AT MOST ONCE per shell session, then short-circuits.
#
# This file is the single source of truth. The shell-specific hook registration
# (add-zsh-hook for zsh, blehook/PROMPT_COMMAND for bash) lives at the bottom,
# dispatched by $ZSH_VERSION/$BASH_VERSION at source time. We do NOT use
# dot_config/{zsh,bash}/*99_chezmoi_reload.{zsh,bash} because the bash side
# would run before this file (dot_bashrc.tmpl loads $BASH_CONFIG_DIR before
# $XDG_CONFIG_HOME/shell to satisfy oh-my-bash's plugins=() prereq) and the
# backend function would not yet be defined.
#
# Opt out:
#   export CHEZMOI_RELOAD_HINT=0    # in ~/.shellrc.adhoc or a per-shell secret file
#
# Cross-file maintenance: see CLAUDE.md "Cross-file maintenance rules" row.

[[ "${CHEZMOI_RELOAD_HINT:-1}" = "0" ]] && return 0

_CZ_RELOAD_SENTINEL="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi/last-apply"
_CZ_RELOAD_BIRTH="$(command mktemp "${TMPDIR:-/tmp}/.cz_birth.XXXXXX" 2>/dev/null)" || _CZ_RELOAD_BIRTH=""

_chezmoi_reload_cleanup() {
    [[ -n "$_CZ_RELOAD_BIRTH" && -f "$_CZ_RELOAD_BIRTH" ]] && rm -f "$_CZ_RELOAD_BIRTH"
}
trap _chezmoi_reload_cleanup EXIT

# Resolve the *current* shell interpreter rather than $SHELL (which reflects
# /etc/passwd / chsh and can lag the real interpreter on first login).
_chezmoi_reload_current_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        printf 'zsh'
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        printf 'bash'
    else
        printf '%s' "$(basename "${SHELL:-sh}")"
    fi
}

# Fires once per session. Hot-path returns when _CZ_RELOAD_SHOWN is set.
_chezmoi_reload_check() {
    [[ -n "$_CZ_RELOAD_SHOWN" ]] && return 0
    [[ -f "$_CZ_RELOAD_SENTINEL" ]] || return 0
    [[ -n "$_CZ_RELOAD_BIRTH" && -f "$_CZ_RELOAD_BIRTH" ]] || return 0
    [[ "$_CZ_RELOAD_SENTINEL" -nt "$_CZ_RELOAD_BIRTH" ]] || return 0

    _CZ_RELOAD_SHOWN=1
    local sh rc
    sh="$(_chezmoi_reload_current_shell)"
    rc="~/.${sh}rc"

    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        local y c r
        y="$(tput setaf 3 2>/dev/null)"
        c="$(tput setaf 6 2>/dev/null)"
        r="$(tput sgr0 2>/dev/null)"
        printf '%sℹ%s chezmoi applied changes — run %sexec %s -l%s or %ssource %s%s to reload\n' \
            "$y" "$r" "$c" "$sh" "$r" "$c" "$rc" "$r"
    else
        printf 'i chezmoi applied changes - run `exec %s -l` or `source %s` to reload\n' \
            "$sh" "$rc"
    fi
}

# Proactive wrappers: run instead of `chezmoi apply` / `chezmoi update` when
# you want the new shell rc to take effect immediately. exec's a fresh login
# shell on success so PATH, completions, hooks, prompts all reinitialise.
cas() {
    chezmoi apply "$@" || return $?
    local sh
    sh="$(_chezmoi_reload_current_shell)"
    exec "$sh" -l
}
cau() {
    chezmoi update "$@" || return $?
    local sh
    sh="$(_chezmoi_reload_current_shell)"
    exec "$sh" -l
}

# czcfg - reconfigure dotfiles prompts on an already-initialized machine.
# Seeds the grouped TUI from your current chezmoi.toml values, then runs
# `chezmoi init --apply --prompt` (the SSOT wrapper, scripts/init/dotfiles_init.py)
# so changed answers actually take effect. `scripts/` isn't deployed, so we
# locate it via `chezmoi source-path`. Non-interactive single-key changes:
#   czcfg --set installLlmTools=true motdStyle=figlet --yes
# Does NOT exec a fresh shell itself — chezmoi apply's reload hint (above) does.
czcfg() {
    if ! command -v uv >/dev/null 2>&1; then
        printf 'czcfg: uv not found; install it first (https://astral.sh/uv).\n' >&2
        return 1
    fi
    local src
    src="$(chezmoi source-path 2>/dev/null)" || {
        printf 'czcfg: could not resolve chezmoi source-path.\n' >&2
        return 1
    }
    uv run --script "${src}/scripts/init/dotfiles_init.py" reconfigure "$@"
}

# Hook registration — source-time dispatch by current shell. The other branch
# is never parsed at runtime, so zsh-only / bash-only syntax inside each
# branch is fine (but we keep both branches POSIX-clean anyway).
if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -Uz add-zsh-hook 2>/dev/null
    add-zsh-hook precmd _chezmoi_reload_check
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ -n "${BLE_VERSION:-}" ] && declare -f blehook >/dev/null 2>&1; then
        blehook PRECMD+=_chezmoi_reload_check
    else
        # Append without duplicating on re-source.
        case "${PROMPT_COMMAND:-}" in
            *_chezmoi_reload_check*) : ;;
            *) PROMPT_COMMAND="_chezmoi_reload_check${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
        esac
    fi
fi
