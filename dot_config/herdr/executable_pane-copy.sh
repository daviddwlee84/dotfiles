#!/usr/bin/env sh
# ~/.config/herdr/pane-copy.sh
# Source: dot_config/herdr/executable_pane-copy.sh (managed by chezmoi)
#
# Copy distilled facts about a herdr pane to the system clipboard. Five targets:
#
#   process  the foreground processes running in the pane (cmdline + pid + cwd)
#   coord    the pane's coordinate in herdr's Session > Workspace > Tab > Pane
#            hierarchy, in a paste-ready form (the ids the herdr CLI accepts, plus
#            the socket path that selects a non-default session — there is NO
#            --session flag on the pane/tab/workspace subcommands)
#   content  the pane's terminal content — visible screen (--source visible) or
#            scrollback (--source recent, the default). `herdr pane read` defaults
#            to only 80 lines unless --lines is passed, so this always requests
#            --lines 1000 — herdr's own hard per-read ceiling (verified: any
#            --lines value above 1000 still returns exactly 1000 lines). A pane
#            with MORE than 1000 lines of retained scrollback (check
#            `herdr pane get $pane | jq .result.pane.scroll.max_offset_from_bottom`)
#            will still only yield its most recent 1000 lines — there is no
#            pagination/offset flag on `pane read` to reach further back.
#   dir      the WORKSPACE ("space") root directory — what the sidebar row you
#            would right-click represents: the cwd of the space's OLDEST tab.
#            Derived by space-root.sh (herdr has no workspace-level cwd field);
#            read the caveat there about the sidebar label drifting from it.
#   cwd      the pane's LIVE working directory — the `abspath`/`pwd` answer,
#            which drifts away from `dir` the moment you cd.
#
# The pane defaults to the CURRENT focused pane (`herdr pane current`); pass a
# pane id to target another. herdr-plus Quick Actions pass $HERDR_PLUS_PANE_ID;
# it falls through to the current-pane lookup when empty.
#
# Clipboard sink is the repo's own `x copy` (dot_dotfiles/bin/executable_x), which
# auto-selects pbcopy / wl-copy / xclip / xsel / OSC 52. We resolve it by absolute
# path fallback because a herdr command-pane / quick-action pane may run us via
# `sh -c` without the interactive-shell PATH.
#
# Usage:
#   pane-copy.sh process [PANE_ID]
#   pane-copy.sh coord   [PANE_ID]
#   pane-copy.sh content [PANE_ID] [--source visible|recent]
#   pane-copy.sh dir     [PANE_ID|WORKSPACE_ID]
#   pane-copy.sh cwd     [PANE_ID]
#
# Consumers: the copy-pane-* quick actions (dot_config/herdr/plugins/config/
# cloudmanic.herdr-plus/quick-actions/). See docs/tools/herdr.md.
set -eu

usage() {
    printf 'usage: %s process|coord|content|dir|cwd [PANE_ID] [--source visible|recent]\n' "$0" >&2
    exit 64
}

# herdr-plus Quick Actions inherit the herdr server's bare PATH (no ~/.local/bin),
# so `herdr` itself is not found there. herdr exports its own binary path to plugin
# processes as $HERDR_BIN_PATH; put that dir (and ~/.local/bin) first.
[ -n "${HERDR_BIN_PATH:-}" ] && PATH="${HERDR_BIN_PATH%/*}:$PATH"
PATH="$PATH:$HOME/.local/bin"
command -v herdr >/dev/null 2>&1 || { echo "pane-copy: herdr not found" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "pane-copy: jq is required" >&2; exit 1; }

# Resolve the clipboard CLI (`x copy`) even without the interactive PATH.
# The managed copy wins over PATH: a stale pre-move `x` can linger in ~/.local/bin
# (bins moved to ~/.dotfiles/bin), and in a Quick Action's bare PATH it would be
# found first and lacks the OSC 52 preference / X_OSC52_TTY support.
if [ -x "$HOME/.dotfiles/bin/x" ]; then
    X_BIN="$HOME/.dotfiles/bin/x"
elif command -v x >/dev/null 2>&1; then
    X_BIN=x
else
    echo "pane-copy: clipboard tool 'x' not found" >&2
    exit 1
fi

action="${1:-}"
[ -n "$action" ] || usage
shift

pane=""
source="recent"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) source="${2:-}"; shift 2 ;;
        --source=*) source="${1#--source=}"; shift ;;
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

# Default to the current focused pane when no id was passed (or an empty env var).
if [ -z "$pane" ]; then
    pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$pane" ] || { echo "pane-copy: could not determine a pane id" >&2; exit 1; }

# OSC 52 routing. A Quick Action runs inside a herdr-plus *overlay* pane that herdr
# tears down the moment the command exits, so an OSC 52 written to that pane's own
# /dev/tty never reaches the outer terminal (`x copy` "succeeds", clipboard stays
# unchanged). Route the sequence through the target pane's long-lived pty instead:
# writing to a pane's pty slave is exactly what a program running in it does, so
# herdr parses and forwards it like a normal in-pane `x copy`. Only done when
# invoked from a Quick Action ($HERDR_PLUS_PANE_ID) and the pty is ours/writable;
# otherwise `x` keeps its own /dev/tty default.
osc52_tty=""
if [ -n "${HERDR_PLUS_PANE_ID:-}" ]; then
    shell_pid=$(herdr pane process-info --pane "$pane" 2>/dev/null \
        | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null || true)
    if [ -n "$shell_pid" ]; then
        t=$(readlink "/proc/$shell_pid/fd/0" 2>/dev/null || true)
        case "$t" in
            /dev/pts/*) [ -c "$t" ] && [ -w "$t" ] && osc52_tty="$t" ;;
        esac
    fi
fi

copy() {
    if [ -n "$osc52_tty" ]; then
        printf '%s' "$1" | X_OSC52_TTY="$osc52_tty" "$X_BIN" copy
    else
        printf '%s' "$1" | "$X_BIN" copy
    fi
}

case "$action" in
    process)
        info=$(herdr pane process-info --pane "$pane" 2>/dev/null) \
            || { echo "pane-copy: failed to read process info for $pane" >&2; exit 1; }
        text=$(printf '%s' "$info" | jq -r '
            .result.process_info as $p
            | "pane \($p.pane_id)  (shell pid \($p.shell_pid))",
              ( $p.foreground_processes[]?
                | "  \(.cmdline)  [pid \(.pid), cwd \(.cwd)]" )
        ')
        [ -n "$text" ] || text="pane $pane  (no foreground processes)"
        copy "$text"
        echo "copied process info for $pane"
        ;;
    coord)
        pj=$(herdr pane get "$pane" 2>/dev/null) \
            || { echo "pane-copy: failed to read pane $pane" >&2; exit 1; }
        ws=$(printf '%s' "$pj" | jq -r '.result.pane.workspace_id // empty')
        tb=$(printf '%s' "$pj" | jq -r '.result.pane.tab_id // empty')
        pn=$(printf '%s' "$pj" | jq -r '.result.pane.pane_id // empty')

        ws_label=$(herdr workspace get "$ws" 2>/dev/null \
            | jq -r '.result.workspace.label // empty' 2>/dev/null || true)
        tb_label=$(herdr tab get "$tb" 2>/dev/null \
            | jq -r '.result.tab.label // empty' 2>/dev/null || true)

        sock="${HERDR_SOCKET_PATH:-}"
        session=$(herdr session list --json 2>/dev/null \
            | jq -r --arg s "$sock" \
                'first(.sessions[]? | select(.socket_path==$s) | .name) // empty' \
                2>/dev/null || true)
        [ -n "$session" ] || session="default"

        text=$(printf 'session=%s\nworkspace=%s%s\ntab=%s%s\npane=%s\n' \
            "$session" \
            "$ws" "${ws_label:+ ($ws_label)}" \
            "$tb" "${tb_label:+ ($tb_label)}" \
            "$pn")
        [ -n "$sock" ] && text=$(printf '%s\nsocket=%s' "$text" "$sock")
        text=$(printf '%s\n# herdr pane get %s' "$text" "$pn")

        copy "$text"
        echo "copied coordinate for $pane"
        ;;
    content)
        case "$source" in
            visible|recent|recent-unwrapped) ;;
            *) echo "pane-copy: --source must be visible|recent|recent-unwrapped" >&2; exit 64 ;;
        esac
        body=$(herdr pane read "$pane" --source "$source" --format text --lines 1000 2>/dev/null) \
            || { echo "pane-copy: failed to read content of $pane" >&2; exit 1; }
        copy "$body"
        echo "copied $source content for $pane"
        ;;
    dir)
        # WORKSPACE ("space") root dir — the sidebar row's directory, NOT the
        # pane's live cwd. Derivation is shared with prefix+C's new-tab helper
        # and the herdr-sesh tv channel; it lives in space-root.sh, which also
        # accepts a bare workspace id. Resolved beside this script rather than
        # via PATH (a command-pane may run us without the interactive PATH).
        here=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
        root=$("$here/space-root.sh" "$pane") || exit 1
        copy "$root"
        echo "copied space dir: $root"
        ;;
    cwd)
        # The pane's LIVE cwd — same answer `abspath` would give inside it.
        # foreground_cwd tracks the running process; cwd is the shell's start dir.
        dir=$(herdr pane get "$pane" 2>/dev/null \
            | jq -r '.result.pane | (.foreground_cwd // .cwd // "")')
        [ -n "$dir" ] || { echo "pane-copy: could not resolve cwd for $pane" >&2; exit 1; }
        copy "$dir"
        echo "copied pane cwd: $dir"
        ;;
    *) usage ;;
esac
