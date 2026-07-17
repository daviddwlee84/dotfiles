#!/usr/bin/env sh
# ~/.config/herdr/path-pick.sh
# Source: dot_config/herdr/executable_path-pick.sh (managed by chezmoi)
#
# Copy-a-file-path picker — the copy-path sibling of url-pick.sh (which OPENS
# URLs). Reads the focused pane, extracts path-like tokens (borrowing extrakto's
# path heuristics), and presents a TWO-TIER fzf list: paths that EXIST relative to
# the pane cwd on top (copied as their resolved ABSOLUTE path), unverified
# candidates (as-seen) below a separator. The choice is copied via `x copy`.
#
# The existence check is the noise-killer extrakto lacks: file paths have no
# scheme:// marker, so regex alone matches dates (2024/01/02), rates (10k/s) and
# fractions (1/2); validating against the pane's live cwd drops nearly all of it.
#
# Runs inside a herdr `[[keys.command]] type="pane"` (a PTY that closes when this
# script exits), bound to prefix+p in .chezmoitemplates/herdr/config.toml. Mirrors
# the sibling pane-copy.sh: $HERDR_ACTIVE_PANE_ID (the keybind var) with a
# `herdr pane current` fallback, `herdr pane read` for the text, `x copy` for the
# clipboard, and an absolute-path `x` fallback because a command pane runs us via
# `sh -c` without the interactive-shell PATH.
#
# Usage:
#   path-pick.sh [PANE_ID] [--source visible|recent] [--cwd DIR]
# PANE defaults to $HERDR_ACTIVE_PANE_ID, else the current focused pane. --source
# defaults to visible; --source recent scans the full scrollback. --cwd is the
# directory relative paths are resolved against for the existence check; it
# defaults to $HERDR_ACTIVE_PANE_CWD → `herdr pane get` foreground_cwd →
# process-info cwd → $PWD.
#
# Consumers: the prefix+p keybind (.chezmoitemplates/herdr/config.toml). See
# docs/tools/herdr.md § "Copy a file path from the pane".
set -eu

usage() { printf 'usage: %s [PANE_ID] [--source visible|recent] [--cwd DIR]\n' "$0" >&2; exit 64; }

command -v herdr >/dev/null 2>&1 || { echo "path-pick: herdr not found" >&2; exit 1; }
command -v fzf   >/dev/null 2>&1 || { echo "path-pick: fzf is required"  >&2; exit 1; }

# Resolve the clipboard CLI (`x copy`) even without the interactive PATH.
if command -v x >/dev/null 2>&1; then
    X_BIN=x
elif [ -x "$HOME/.dotfiles/bin/x" ]; then
    X_BIN="$HOME/.dotfiles/bin/x"
else
    echo "path-pick: clipboard tool 'x' not found" >&2
    exit 1
fi

pane=""
source="visible"
cwd=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) source="${2:-}"; shift 2 ;;
        --source=*) source="${1#--source=}"; shift ;;
        --cwd) cwd="${2:-}"; shift 2 ;;
        --cwd=*) cwd="${1#--cwd=}"; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *)
            if [ -z "$pane" ]; then
                pane="$1"
                shift
            else
                usage
            fi
            ;;
    esac
done

case "$source" in
    visible|recent|recent-unwrapped) ;;
    *) echo "path-pick: --source must be visible|recent" >&2; exit 64 ;;
esac

# Resolve pane (keybind passes $HERDR_ACTIVE_PANE_ID; fall back to current).
if [ -z "$pane" ]; then
    command -v jq >/dev/null 2>&1 || { echo "path-pick: jq required to resolve current pane" >&2; exit 1; }
    pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$pane" ] || { echo "path-pick: could not determine a pane id" >&2; exit 1; }

# Resolve cwd for existence checks: --cwd → pane.foreground_cwd → process cwd → $PWD.
if [ -z "$cwd" ] && command -v jq >/dev/null 2>&1; then
    cwd=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null || true)
    [ -n "$cwd" ] || cwd=$(herdr pane process-info --pane "$pane" 2>/dev/null \
        | jq -r '.result.process_info.foreground_processes[0].cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"

content=$(herdr pane read "$pane" --source "$source" --format text 2>/dev/null) \
    || { echo "path-pick: failed to read pane $pane" >&2; exit 1; }

# Path candidates (extrakto path heuristics, POSIX-ized): slash-bearing tokens
# (abs /…, home ~/…, rel ./ ../ a/b/c) + bare filename.ext. rstrip trailing
# ",):; then drop rate/fraction noise (extrakto's exclude: 10k/s, 1/2). dedupe.
cands=$(printf '%s\n' "$content" \
    | grep -oE '(~|\.\.?)?/?[A-Za-z0-9._+~-]+(/[A-Za-z0-9._+~-]+)+|[A-Za-z0-9._+-]+\.[A-Za-z0-9]{1,8}' \
    | sed -E 's/[",):;]+$//' \
    | grep -vE '^[0-9]+/[0-9]+$|[kKmMgG]/s$' \
    | grep -v '^$' | awk '!seen[$0]++' || true)

if [ -z "$cands" ]; then
    printf 'path-pick: no file paths found in pane %s (%s)\n' "$pane" "$source" >&2
    sleep 1.5   # command pane closes on exit — pause so the message is visible
    exit 0
fi

# Two tiers: exists-under-cwd (resolved absolute) vs the rest (as-seen).
exist=""
maybe=""
OLDIFS=$IFS
IFS='
'
for c in $cands; do
    base=$(printf '%s' "$c" | sed -E 's/:[0-9]+(:[0-9]+)?$//')   # strip :line[:col] for the test
    case "$base" in
        /*)   abs="$base" ;;
        \~/*) abs="$HOME/${base#\~/}" ;;
        *)    abs="$cwd/$base" ;;
    esac
    if [ -e "$abs" ]; then
        rp=$(CDPATH=''; cd -- "$(dirname -- "$abs")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename -- "$abs")") \
            || rp="$abs"
        exist="$exist$rp
"
    else
        maybe="$maybe$c
"
    fi
done
IFS=$OLDIFS

exist=$(printf '%s' "$exist" | grep -v '^$' | sort -u || true)
maybe=$(printf '%s' "$maybe" | grep -v '^$' | sort -u || true)

SEP='────────  unverified (not found under cwd)  ────────'
list=$(
    [ -n "$exist" ] && printf '%s\n' "$exist"
    [ -n "$maybe" ] && { printf '%s\n' "$SEP"; printf '%s\n' "$maybe"; }
)

# fzf multi-select; Esc / no-match (exit 130 / 1) → clean no-op.
chosen=$(printf '%s\n' "$list" | fzf --multi --no-sort --height=100% --border \
    --prompt='path> ' --header="Enter=copy · Tab=multi · cwd=$cwd") || exit 0

# Drop the separator if it slipped into the selection; copy the rest.
chosen=$(printf '%s\n' "$chosen" | grep -vFx "$SEP" | grep -v '^$' || true)
[ -n "$chosen" ] || exit 0

printf '%s' "$chosen" | "$X_BIN" copy
echo "copied $(printf '%s\n' "$chosen" | grep -c .) path(s)"
