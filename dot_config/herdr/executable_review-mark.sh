#!/usr/bin/env sh
# ~/.config/herdr/review-mark.sh
# Source: dot_config/herdr/executable_review-mark.sh (managed by chezmoi)
#
# Set / clear / toggle a per-pane "review-pending" flag on a herdr pane, using
# herdr's per-pane custom-status metadata (`herdr pane report-metadata … --source
# review --custom-status …`). This is the herdr analog of tmux's
# `@bookmark_status` (dot_config/tmux/executable_toggle-bookmark.sh) — the
# problem it solves is the SAME: keep a session visibly flagged as "I still need
# to review this" even after the agent's own state flips to idle.
#
# Why custom-status and not agent state: it is pushed under a dedicated
# `--source review`, ORTHOGONAL to herdr's native agent detection. Verified: a
# pane can carry `custom_status:"⭐ REVIEW"` while `agent_status:"idle"` — so
# peeking into a done pane (which collapses it to idle) does NOT wipe the flag.
# Omitting --ttl-ms makes it persistent (no auto-expiry).
#
# The single source of truth for the mark IS herdr itself: `herdr pane get`
# surfaces the `custom_status` field, and `herdr pane list` (native JSON, NO
# --json flag) lets the `tv herdr-review` inbox enumerate flagged panes. No
# sidecar file.
#
# Usage:
#   review-mark.sh set    <pane_id> [glyph-text]   # default "⭐ REVIEW"
#   review-mark.sh clear  <pane_id>
#   review-mark.sh toggle <pane_id> [glyph-text]   # clear if flagged, else set
#
# Consumers: hmark/hunmark (dot_config/shell/24_herdr.sh), the prefix+m keybind
# (.chezmoitemplates/herdr/config.toml), and the herdr-review tv channel's
# focus_clear action. Keep the marker MATCH substring ("REVIEW") in sync with
# that channel's jq filter (dot_config/television/cable/herdr-review.toml).
set -eu

SOURCE_ID='review'
MATCH='REVIEW'                 # substring the tv channel filters on (glyph-agnostic)
DEFAULT_STATUS='⭐ REVIEW'

usage() {
    printf 'usage: %s set|clear|toggle <pane_id> [glyph-text]\n' "$0" >&2
    exit 64
}

command -v herdr >/dev/null 2>&1 || { echo "review-mark: herdr not found" >&2; exit 1; }

action="${1:-}"
pane="${2:-}"
status="${3:-$DEFAULT_STATUS}"

[ -n "$action" ] || usage
[ -n "$pane" ] || usage

_set() {
    herdr pane report-metadata "$pane" --source "$SOURCE_ID" --custom-status "$status" >/dev/null
    echo "review flag set on $pane"
}

_clear() {
    herdr pane report-metadata "$pane" --source "$SOURCE_ID" --clear-custom-status >/dev/null
    echo "review flag cleared on $pane"
}

case "$action" in
    set)   _set ;;
    clear) _clear ;;
    toggle)
        command -v jq >/dev/null 2>&1 || { echo "review-mark: jq is required for toggle" >&2; exit 1; }
        current=$(herdr pane get "$pane" 2>/dev/null \
            | jq -r '.result.pane.custom_status // ""' 2>/dev/null || true)
        case "$current" in
            *"$MATCH"*) _clear ;;
            *)          _set ;;
        esac ;;
    *) usage ;;
esac
