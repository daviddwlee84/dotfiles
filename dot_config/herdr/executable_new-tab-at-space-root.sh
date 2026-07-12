#!/usr/bin/env sh
# ~/.config/herdr/new-tab-at-space-root.sh
# Source: dot_config/herdr/executable_new-tab-at-space-root.sh (managed by chezmoi)
#
# Open a NEW TAB rooted at the WORKSPACE ("space") directory, NOT the focused
# pane's live cwd.
#
# Why this exists: on herdr >=0.7.x, `new_cwd = "follow"` makes a new tab inherit
# the FOCUSED pane's cwd — herdr issue #912 (https://github.com/ogulcancelik/herdr/issues/912)
# changed `follow` so new tabs behave like pane splits, and the older "new tab
# opens at the workspace's initial dir" was treated as a bug and removed. There
# is NO new_cwd value for "workspace dir", so we compute it and pass it via
# `herdr tab create --cwd`. (herdr exposes no workspace-level cwd field either —
# `herdr workspace get` has no cwd — so it must be derived.)
#
# "Space dir" = the workspace's ROOT tab's pane cwd, where the root tab is the
# lowest-numbered tab — the one whose live-cwd basename herdr uses as the
# workspace label. We prefer the live cwd (foreground_cwd, matches the label),
# falling back to the shell startup cwd.
#
# Bound to prefix+C (.chezmoitemplates/herdr/config.toml). prefix+c and the mouse
# "+" button keep herdr's native follow-the-focused-pane behavior. Uses the
# keybind-context $HERDR_ACTIVE_PANE_ID (falls back to ambient $HERDR_PANE_ID).
#
# Usage:
#   new-tab-at-space-root.sh [pane_id]   # pane_id defaults to the current pane
set -eu

command -v herdr >/dev/null 2>&1 || { echo "new-tab-at-space-root: herdr not found" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "new-tab-at-space-root: jq is required" >&2; exit 1; }

pane="${1:-${HERDR_ACTIVE_PANE_ID:-${HERDR_PANE_ID:-}}}"
[ -n "$pane" ] || { echo "new-tab-at-space-root: no pane id (pass one, or run inside herdr)" >&2; exit 64; }

wid=$(herdr pane get "$pane" | jq -r '.result.pane.workspace_id // ""')
[ -n "$wid" ] || { echo "new-tab-at-space-root: could not resolve workspace for pane $pane" >&2; exit 1; }

# Root tab = lowest tab number in the workspace (herdr labels the space after it).
root_tab=$(herdr tab list --workspace "$wid" | jq -r '.result.tabs | sort_by(.number) | .[0].tab_id // ""')
[ -n "$root_tab" ] || { echo "new-tab-at-space-root: no tabs in workspace $wid" >&2; exit 1; }

# `herdr tab get` returns tab metadata only (no pane cwd), so read the root tab's
# pane cwd from the full pane list. Prefer live cwd so it matches the space label.
root=$(herdr pane list | jq -r --arg t "$root_tab" \
    '.result.panes | map(select(.tab_id==$t)) | .[0] // {} | (.foreground_cwd // .cwd // "")')
[ -n "$root" ] || { echo "new-tab-at-space-root: could not resolve root dir for $root_tab" >&2; exit 1; }

exec herdr tab create --workspace "$wid" --cwd "$root" --focus
