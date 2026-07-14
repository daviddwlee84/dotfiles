#!/usr/bin/env sh
# ~/.config/herdr/pane-copy.sh
# Source: dot_config/herdr/executable_pane-copy.sh (managed by chezmoi)
#
# Copy distilled facts about a herdr pane to the system clipboard. Three targets:
#
#   process  the foreground processes running in the pane (cmdline + pid + cwd)
#   coord    the pane's coordinate in herdr's Session > Workspace > Tab > Pane
#            hierarchy, in a paste-ready form (the ids the herdr CLI accepts, plus
#            the socket path that selects a non-default session — there is NO
#            --session flag on the pane/tab/workspace subcommands)
#   content  the pane's terminal content — visible screen (--source visible) or
#            the full retained scrollback (--source recent, the default)
#
# The pane defaults to the CURRENT focused pane (`herdr pane current`); pass a
# pane id to target another. herdr's keybind context passes $HERDR_ACTIVE_PANE_ID
# and herdr-plus Quick Actions pass $HERDR_PLUS_PANE_ID — both are wired to call
# this, and both fall through to the current-pane lookup when empty.
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
#
# Consumers: the prefix+P/L/V/B keybinds (.chezmoitemplates/herdr/config.toml) and
# the copy-pane-* quick actions (dot_config/herdr/plugins/config/
# cloudmanic.herdr-plus/quick-actions/). See docs/tools/herdr.md.
set -eu

usage() {
    printf 'usage: %s process|coord|content [PANE_ID] [--source visible|recent]\n' "$0" >&2
    exit 64
}

command -v herdr >/dev/null 2>&1 || { echo "pane-copy: herdr not found" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "pane-copy: jq is required" >&2; exit 1; }

# Resolve the clipboard CLI (`x copy`) even without the interactive PATH.
if command -v x >/dev/null 2>&1; then
    X_BIN=x
elif [ -x "$HOME/.dotfiles/bin/x" ]; then
    X_BIN="$HOME/.dotfiles/bin/x"
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

copy() { printf '%s' "$1" | "$X_BIN" copy; }

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
        body=$(herdr pane read "$pane" --source "$source" --format text 2>/dev/null) \
            || { echo "pane-copy: failed to read content of $pane" >&2; exit 1; }
        copy "$body"
        echo "copied $source content for $pane"
        ;;
    *) usage ;;
esac
