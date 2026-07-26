#!/usr/bin/env sh
# ~/.config/herdr/run-command.sh
# Source: dot_config/herdr/executable_run-command.sh (managed by chezmoi)
#
# Run an ARBITRARY command in the focused pane's cwd, inside a floating popup that
# closes by itself when the command exits. This is the generalisation of the
# hardcoded `prefix+G` (lazygit) binding — the tmux `display-popup -E` experience,
# with a command you pick or type instead of one baked into the config.
#
# Why a popup and not the alternatives:
#   - `type = "pane"` (prefix+G/M/N/`) splits the TILED layout for the duration.
#   - `prefix+c` + type + `exit` is four steps and churns the tab bar.
#   - `type = "popup"` (herdr >= 0.7.4) is session-modal and floats ABOVE the
#     layout, so nothing reflows and you land exactly where you were.
# It also cannot live as a herdr-plus Quick Action (prefix+y): those run through
# `sh -c` with no PTY/stdin — the same reason btop/nvtop are command panes — and
# every Quick Action is a fixed command string with no free-text field.
#
# Bound to prefix+E in .chezmoitemplates/herdr/config.toml.
#
# Usage:
#   run-command.sh [--cwd DIR] [--sh] [--] [QUERY...]
# --cwd  directory to run in; defaults to $HERDR_ACTIVE_PANE_CWD (injected by the
#        keybind) → `herdr pane get` foreground_cwd → $PWD. Preferring the env var
#        means this keeps working even when the CLI is protocol-mismatched with a
#        stale server.
# --sh   run via `sh -c` (fast, no aliases) instead of the default `$SHELL -ic`
#        (sources the interactive rc, so this repo's aliases/functions resolve).
# QUERY  seeds the picker (and, with no fzf, prefills nothing — it is run as-is).
#
# Exit behaviour is governed by HERDR_RUN_HOLD:
#   fail (default)  close on success, wait for a key on non-zero exit
#   always          always wait for a key
#   never           never wait
#
# Consumers: the prefix+E keybind (.chezmoitemplates/herdr/config.toml). See
# docs/tools/herdr.md § "Run any command in a popup".
set -eu

usage() { printf 'usage: %s [--cwd DIR] [--sh] [--] [QUERY...]\n' "$0" >&2; exit 64; }

cwd=""
use_sh=0
query=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --cwd) cwd="${2:-}"; shift 2 ;;
        --cwd=*) cwd="${1#--cwd=}"; shift ;;
        --sh) use_sh=1; shift ;;
        -h|--help) usage ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
# Everything left (before or after `--`) seeds the query.
if [ "$#" -gt 0 ]; then
    query="$*"
fi

# --- cwd resolution: --cwd → $HERDR_ACTIVE_PANE_CWD → pane foreground_cwd → $PWD
# (same chain as the sibling path-pick.sh).
if [ -z "$cwd" ]; then
    cwd="${HERDR_ACTIVE_PANE_CWD:-}"
fi
if [ -z "$cwd" ] && command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    pane="${HERDR_ACTIVE_PANE_ID:-}"
    if [ -z "$pane" ]; then
        pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
    fi
    if [ -n "$pane" ]; then
        cwd=$(herdr pane get "$pane" 2>/dev/null \
            | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty' 2>/dev/null || true)
    fi
fi
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# --- history source ---------------------------------------------------------
# $HISTFILE is a zsh interactive var and is NOT exported into the `sh -c` context
# a keybind command runs in, so default it explicitly.
histfile="${HISTFILE:-$HOME/.zsh_history}"

# Newest-first, de-duplicated, timestamps stripped.
#   - LC_ALL=C is REQUIRED: ~/.zsh_history carries non-UTF8 bytes and BSD sed
#     aborts with "sed: RE error: illegal byte sequence" under a UTF-8 locale.
#   - The reverse is done in awk because `tail -r` is BSD-only and `tac` GNU-only.
#   - Lines ending in a backslash are multi-line history entries; skip them.
_history() {
    [ -r "$histfile" ] || return 0
    LC_ALL=C sed 's/^: [0-9]*:[0-9]*;//' "$histfile" 2>/dev/null \
        | grep -v '\\$' \
        | awk 'NF' \
        | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) if(!seen[a[i]]++) print a[i]}'
}

# --- pick the command -------------------------------------------------------
cmd=""
if command -v fzf >/dev/null 2>&1; then
    # --print-query makes the three outcomes distinguishable by exit code:
    #   0   picked an entry   → line 1 = query, line 2 = selection
    #   1   no match + Enter  → line 1 = query only (a brand-new command)
    #   130 Esc               → abort
    set +e
    out=$(_history | fzf \
        --print-query --no-sort --height=100% --border \
        --query="$query" \
        --prompt="run [$(basename "$cwd")]> ")
    rc=$?
    set -e
    case "$rc" in
        0) cmd=$(printf '%s\n' "$out" | sed -n '2p') ;;
        1) cmd=$(printf '%s\n' "$out" | sed -n '1p') ;;
        *) exit 0 ;;   # 130 = Esc, or fzf failed — run nothing
    esac
else
    if [ -n "$query" ]; then
        cmd="$query"
    else
        printf 'run [%s]> ' "$(basename "$cwd")"
        IFS= read -r cmd || exit 0
    fi
fi

[ -n "$cmd" ] || exit 0

# --- run it -----------------------------------------------------------------
cd "$cwd" || { echo "run-command: cannot cd to $cwd" >&2; exit 1; }

set +e
if [ "$use_sh" -eq 1 ]; then
    sh -c "$cmd"
else
    # -i so the interactive rc is sourced and this repo's aliases/functions exist.
    "${SHELL:-/bin/sh}" -ic "$cmd"
fi
rc=$?
set -e

# --- hold policy ------------------------------------------------------------
hold="${HERDR_RUN_HOLD:-fail}"
case "$hold" in
    never) ;;
    always) _wait=1 ;;
    *) [ "$rc" -ne 0 ] && _wait=1 ;;
esac
if [ "${_wait:-0}" -eq 1 ]; then
    [ "$rc" -ne 0 ] && printf '\n[exit %s] ' "$rc" || printf '\n[exit 0] '
    printf 'press Enter to close…'
    IFS= read -r _ || true
fi

exit "$rc"
