#!/usr/bin/env bash
# Source emitter for the `super-productivity` tv channel.
#
# Usage:
#   super-productivity-source.sh <tasks-active|tasks-all|tasks-archived|projects|tags>
#
# Emits TSV rows: <id>\t<marker>\t<context>\t<title>
#
# Talks to Super Productivity's Local REST API on http://127.0.0.1:3876.
# Requires Super Productivity desktop ≥ 18.0.0 (the API was added in
# upstream PR #6981, first shipped in v18.0.0 on 2026-03-26). Older
# versions (e.g. 17.x) do not have the HTTP server at all — they will
# look "API down" no matter what setting you flip.
#
# To enable in v18+:
#   Settings → Misc → "Enable local REST API"
# (NOT in Sync & Export — that section only configures Dropbox/WebDAV/
# SuperSync data sync, which is unrelated to the REST API.)
#
# Reverse-engineered route reference: docs/tools/super-productivity.md
# Upstream source of truth (as of 2026-04):
#   electron/local-rest-api.ts
#   electron/shared-with-frontend/local-rest-api.model.ts
#   src/app/core/electron/local-rest-api-handler.service.ts

set -u

API="${SP_API_BASE:-http://127.0.0.1:3876}"
mode="${1:-tasks-active}"

# ---------------------------------------------------------------------------
# Mode validation BEFORE preflight, so a typo doesn't get masked by API-down.
# ---------------------------------------------------------------------------
case "$mode" in
  tasks-active|tasks-all|tasks-archived|projects|tags) ;;
  *)
    printf '0\t⚠ unknown mode\t-\t%s (use tasks-active|tasks-all|tasks-archived|projects|tags)\n' "$mode" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Preflight: GET /health is the one route that responds before the renderer
# is ready, so we use it as a liveness probe. -m 1 keeps `tv` snappy even
# when SP isn't running (TCP RST returns immediately on localhost; this
# 1s cap is for the rare case where the port is stuck).
#
# When the probe fails, we try to differentiate three cases by reading the
# installed app version from the macOS app bundle (Linux/other: skip detection
# and fall through to generic message):
#   1. SP not installed         → install hint
#   2. SP installed but < v18   → upgrade hint (REST API doesn't exist yet)
#   3. SP ≥ v18 + API down      → toggle hint (most common after upgrade)
# ---------------------------------------------------------------------------
if ! curl -sf -m 1 "$API/health" >/dev/null 2>&1; then
  hint="Needs Super Productivity ≥ 18.0.0, then Settings → Misc → Enable Local REST API"
  if [ "$(uname)" = "Darwin" ] && [ -f "/Applications/Super Productivity.app/Contents/Info.plist" ]; then
    sp_version=$(defaults read "/Applications/Super Productivity.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "")
    sp_major="${sp_version%%.*}"
    if [ -n "$sp_major" ] && [ "$sp_major" -ge 18 ] 2>/dev/null; then
      hint="SP $sp_version installed but API not responding — open SP, Settings → Misc → Enable Local REST API, then restart SP"
    elif [ -n "$sp_version" ]; then
      hint="SP $sp_version is too old for REST API — run: brew upgrade --cask super-productivity (need ≥ 18.0.0)"
    else
      hint="Super Productivity not installed — run: brew install --cask super-productivity"
    fi
  fi
  printf '0\t⚠ API down\tv18+\t%s\n' "$hint"
  exit 0
fi

# ---------------------------------------------------------------------------
# Project-id → title cache (5s TTL). Tasks reference projects by id only,
# so without this we'd need a JOIN per row. One GET /projects per refresh
# cycle keeps the channel responsive.
#
# Response envelope: all routes return `{"ok": bool, "data": <payload>}`.
# We extract `.data` once at fetch time so downstream jq pipelines see the
# raw payload (array/object), not the wrapper.
# ---------------------------------------------------------------------------
cache="${TMPDIR:-/tmp}/sp-projects-${UID:-$(id -u)}.json"
mtime() {
  if stat -f %m "$1" 2>/dev/null; then return; fi
  stat -c %Y "$1" 2>/dev/null
}
if [ ! -f "$cache" ] || [ "$(($(date +%s) - $(mtime "$cache" 2>/dev/null || echo 0)))" -gt 5 ]; then
  curl -sf -m 2 "$API/projects" 2>/dev/null | jq '.data // []' >"$cache" 2>/dev/null \
    || echo '[]' >"$cache"
fi

# Current task id (for the ▶ marker on the active row). Empty if no task is
# focused; the API returns {ok:true, data:null} when nothing is active.
current=$(curl -sf -m 2 "$API/task-control/current" 2>/dev/null | jq -r '.data.id // empty' 2>/dev/null || true)

emit_tasks() {
  # $1 = query string suffix (e.g. "source=active&includeDone=false")
  # $2 = marker style: "current" | "done" | "archived"
  local qs="$1" style="$2"
  curl -sf -m 3 "$API/tasks?$qs" 2>/dev/null \
    | jq -r --arg cur "$current" --arg style "$style" --slurpfile projs "$cache" '
        ($projs[0] | map({(.id): .title}) | add) as $pmap
        | .data[]
        | . as $t
        | (
            if   $style == "current"  then (if .id == $cur then "▶ active"
                                            else "○ pending" end)
            elif $style == "done"     then (if .isDone     then "✓ done"
                                            elif .id == $cur then "▶ active"
                                            else "○ pending" end)
            elif $style == "archived" then "📦 archived"
            else "○" end
          ) as $marker
        | ($pmap[.projectId] // "no-project") as $proj
        | [ .id, $marker, $proj, .title ] | @tsv'
}

case "$mode" in
  tasks-active)
    emit_tasks "source=active&includeDone=false" "current"
    ;;
  tasks-all)
    emit_tasks "source=active&includeDone=true" "done"
    ;;
  tasks-archived)
    emit_tasks "source=archived&includeDone=true" "archived"
    ;;
  projects)
    curl -sf -m 3 "$API/projects" 2>/dev/null \
      | jq -r '.data[] | [
            .id,
            (if .isArchived then "📦 archived" else "○ active" end),
            ((.taskIds // [] | length | tostring) + " tasks"),
            .title
          ] | @tsv'
    ;;
  tags)
    curl -sf -m 3 "$API/tags" 2>/dev/null \
      | jq -r '.data[] | [
            .id,
            "🏷",
            (.color // "no-color"),
            .title
          ] | @tsv'
    ;;
esac
