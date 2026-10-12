#!/usr/bin/env sh
# ~/.config/herdr/sidecar.sh — prefix+S command-pane launcher.
# Herdr creates/focuses a temporary right split; only undo its automatic zoom.
# Quitting Sidecar lets Herdr close the pane and restore the source focus/zoom.
set -eu

if [ "${HERDR_ENV:-}" != 1 ] || [ -z "${HERDR_PANE_ID:-}" ]; then
	printf '%s\n' 'sidecar: run this launcher from a Herdr command pane (prefix+S).' >&2
	exit 1
fi

herdr_bin=${HERDR_BIN_PATH:-herdr}

fail() {
	rc=$1
	shift
	printf 'sidecar: %s\n' "$*" >&2
	"$herdr_bin" notification show 'Sidecar could not open' --body "$*" >/dev/null 2>&1 || :
	exit "$rc"
}

sidecar_bin=$(command -v sidecar) || fail 127 \
	'Sidecar is not installed. Enable installCodingAgents with dotcfg, then apply the configuration.'

# --current identifies this NEW pane, not HERDR_ACTIVE_PANE_ID (the source).
"$herdr_bin" pane zoom --current --off >/dev/null || fail 1 'Could not show the Sidecar split.'

# The source live cwd is supplied by Herdr; quote it without shell evaluation.
exec "$sidecar_bin" --project "${HERDR_ACTIVE_PANE_CWD:-$PWD}"
