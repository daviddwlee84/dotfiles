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
# "Space dir" = the cwd of the workspace's OLDEST surviving tab. That derivation
# is NOT inlined here: it lives in the sibling ~/.config/herdr/space-root.sh,
# shared with `pane-copy.sh dir` (prefix+d) and the herdr-sesh tv channel. Change
# it there, once — including the caveat about the sidebar label drifting from it.
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

# Root dir derivation is shared — see space-root.sh. Resolve it beside this
# script rather than via PATH: a herdr command-pane may run us without the
# interactive PATH.
here=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
root=$("$here/space-root.sh" "$wid") || exit 1

exec herdr tab create --workspace "$wid" --cwd "$root" --focus
