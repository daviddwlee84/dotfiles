#!/usr/bin/env sh
# ~/.config/herdr/space-root.sh
# Source: dot_config/herdr/executable_space-root.sh (managed by chezmoi)
#
# Print the WORKSPACE ("space") root directory for a herdr workspace, given
# either a workspace id (`wP`) or any pane id inside it (`wP:p29`).
#
# Why this script exists: **herdr exposes no workspace-level cwd.** `herdr
# workspace get` returns label / number / tab_count / pane_count and nothing
# else (verified on 0.7.5), so "the directory this space is about" has to be
# derived. It is the SSOT for that derivation — three consumers would otherwise
# each carry their own copy and silently drift:
#
#   new-tab-at-space-root.sh   prefix+C  (new tab at the space dir)
#   pane-copy.sh dir           prefix+y → "Copy space: dir" Quick Action
#   herdr-sesh tv channel      prefix+T, Alt+Y (copy any workspace's dir)
#
# "Space root" = the cwd of the workspace's OLDEST surviving tab. Note `.number`
# is a monotonic creation counter, NOT the display index (a workspace can hold
# tabs numbered 10/13/14/15 displayed as 1/2/3/4), so sort_by(.number)[0] is the
# oldest tab, which is the right notion of "the tab this space started as". We
# prefer the LIVE cwd (`foreground_cwd`) over the shell's startup cwd.
#
# CAVEAT — this is a best-effort answer, not an authoritative one. herdr's
# sidebar LABEL is pinned when the workspace is created and is never re-derived,
# so once you `cd` inside the oldest tab the two drift apart and nothing in the
# API can recover the original path. Observed live: a space labelled
# `2026-05-14-grafana-provisioning-with-docker-otel-lgtm` whose oldest tab sits
# in `…/grafana/dashboards/Jingle.AI`. There is no better source — `workspace
# get` and `herdr api snapshot` return the same cwd-less workspace object.
#
# A pane id is resolved through `herdr pane get` rather than by string-splitting
# on the ":" — the id format is hierarchical in practice (`wP` / `wP:t7` /
# `wP:pA`) but that is an observation, not a documented guarantee.
#
# Usage:
#   space-root.sh <workspace_id|pane_id>
#   space-root.sh                        # defaults to the current pane's space
set -eu

command -v herdr >/dev/null 2>&1 || { echo "space-root: herdr not found" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "space-root: jq is required" >&2; exit 1; }

target="${1:-${HERDR_ACTIVE_PANE_ID:-${HERDR_PANE_ID:-}}}"

# No id anywhere (ran outside herdr's keybind context) → ask for the focused pane.
if [ -z "$target" ]; then
    target=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$target" ] || { echo "space-root: no workspace or pane id (pass one, or run inside herdr)" >&2; exit 64; }

case "$target" in
    *:*)
        wid=$(herdr pane get "$target" 2>/dev/null | jq -r '.result.pane.workspace_id // ""')
        [ -n "$wid" ] || { echo "space-root: could not resolve workspace for pane $target" >&2; exit 1; }
        ;;
    *)
        wid="$target"
        ;;
esac

# Root tab = the workspace's OLDEST tab (lowest creation counter, not display index).
root_tab=$(herdr tab list --workspace "$wid" 2>/dev/null \
    | jq -r '.result.tabs | sort_by(.number) | .[0].tab_id // ""')
[ -n "$root_tab" ] || { echo "space-root: no tabs in workspace $wid" >&2; exit 1; }

# `herdr tab get` returns tab metadata only (no pane cwd), so read the root tab's
# pane cwd from the full pane list. foreground_cwd = where the tab actually is
# now; .cwd = the shell's startup dir, used only when there is no live reading.
root=$(herdr pane list 2>/dev/null | jq -r --arg t "$root_tab" \
    '.result.panes | map(select(.tab_id==$t)) | .[0] // {} | (.foreground_cwd // .cwd // "")')
[ -n "$root" ] || { echo "space-root: could not resolve root dir for $root_tab" >&2; exit 1; }

printf '%s\n' "$root"
