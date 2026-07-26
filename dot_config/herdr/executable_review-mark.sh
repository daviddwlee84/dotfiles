#!/usr/bin/env sh
# ~/.config/herdr/review-mark.sh
# Source: dot_config/herdr/executable_review-mark.sh (managed by chezmoi)
#
# Set / clear / toggle a per-pane "review-pending" flag on a herdr pane, using
# herdr's per-pane metadata TOKENS (`herdr pane report-metadata … --source review
# --token review=…`). This is the herdr analog of tmux's
# `@bookmark_status` (dot_config/tmux/executable_toggle-bookmark.sh) — the
# problem it solves is the SAME: keep a session visibly flagged as "I still need
# to review this" even after the agent's own state flips to idle.
#
# Why a metadata token and not agent state: it is pushed under a dedicated
# `--source review`, ORTHOGONAL to herdr's native agent detection. A pane can
# carry `tokens.review = "⭐ REVIEW"` while `agent_status:"idle"` — so peeking
# into a done pane (which collapses it to idle) does NOT wipe the flag.
# Omitting --ttl-ms makes it persistent (no auto-expiry).
#
# herdr >= 0.7.4 ONLY. herdr 0.7.4 removed `--custom-status` / the flat
# `custom_status` field in favour of this namespaced token map (up to 32 tokens
# per pane, names matching ^[A-Za-z0-9_-]{1,32}$). The removal is NOT listed as a
# breaking change upstream — on an older herdr this script dies with
# `unknown --custom-status`. See pitfalls/herdr-0.7.4-drops-custom-status.md.
#
# Unlike `custom_status`, a token is NOT rendered by the sidebar automatically —
# it only shows where a row layout references it. `$review` is wired into
# `[ui.sidebar.agents] rows` in .chezmoitemplates/herdr/config.toml; drop the
# token name here and you must drop it there too.
#
# The single source of truth for the mark IS herdr itself: `herdr pane get`
# surfaces `tokens`, and `herdr pane list` (native JSON, NO --json flag) lets the
# `tv herdr-review` inbox enumerate flagged panes. No sidecar file.
#
# Usage:
#   review-mark.sh set    <pane_id> [glyph-text]   # default "⭐ REVIEW"
#   review-mark.sh clear  <pane_id>
#   review-mark.sh toggle <pane_id> [glyph-text]   # clear if flagged, else set
#
# Consumers: hmark/hunmark (dot_config/shell/24_herdr.sh), the prefix+m keybind
# (.chezmoitemplates/herdr/config.toml), and the herdr-review tv channel's
# focus_clear action. Keep TOKEN in sync with the `.tokens.<name>` lookups in
# that channel (dot_config/television/cable/herdr-review.toml) and with the
# `$review` token in the sidebar row layout.
set -eu

SOURCE_ID='review'
TOKEN='review'                 # metadata token name; the tv channel keys off its PRESENCE
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
    herdr pane report-metadata "$pane" --source "$SOURCE_ID" --token "$TOKEN=$status" >/dev/null
    echo "review flag set on $pane"
}

_clear() {
    herdr pane report-metadata "$pane" --source "$SOURCE_ID" --clear-token "$TOKEN" >/dev/null
    echo "review flag cleared on $pane"
}

case "$action" in
    set)   _set ;;
    clear) _clear ;;
    toggle)
        command -v jq >/dev/null 2>&1 || { echo "review-mark: jq is required for toggle" >&2; exit 1; }
        # Presence of the token IS the flag — a cleared token is absent from the
        # map, so no substring match is needed (unlike the pre-0.7.4 single
        # `custom_status` string that every source shared).
        current=$(herdr pane get "$pane" 2>/dev/null \
            | jq -r --arg t "$TOKEN" '.result.pane.tokens[$t] // ""' 2>/dev/null || true)
        case "$current" in
            '') _set ;;
            *)  _clear ;;
        esac ;;
    *) usage ;;
esac
