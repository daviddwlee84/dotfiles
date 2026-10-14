#!/usr/bin/env sh
# ~/.config/herdr/agent-open.sh
# Source: dot_config/herdr/executable_agent-open.sh (managed by chezmoi)
#
# Open a coding agent in a new split or tab next to the focused herdr pane.
# Driven by the "Agent: …" Quick Actions (prefix+y) and the prefix+alt+c/x/t/r
# hotkeys (.chezmoitemplates/herdr/config.toml).
#
# Why the env var instead of `herdr pane run`: herdr can only spawn a pane with
# the default shell, and typing a command into it waits for the full interactive
# rc (~0.3s+). Instead the new pane's shell gets HERDR_AGENT_LAUNCH, and a guard
# at the very top of ~/.zshrc / ~/.bashrc hands it to ~/.config/herdr/agent-run.sh
# BEFORE the heavy init — the rest of the rc runs after the agent exits, so the
# pane falls back to a normal shell. HERDR_AGENT_FULL_RC=1 opts out (slow path:
# plain split, then `herdr pane run` into the fully loaded shell).
#
# Only allowlisted tokens are forwarded; agent-run.sh re-checks them and never
# evals anything. See docs/tools/herdr.md § "Open a coding agent".
#
# Usage:
#   agent-open.sh <right|down|tab> <agent> <run|off>
#   agent-open.sh last            # repeat the previous choice
#   agent:  claude codex opencode claude-copilot codex-copilot
#   record: run = SpecStory live recording, off = direct
set -eu

herdr_bin=${HERDR_BIN_PATH:-herdr}
state="${XDG_CACHE_HOME:-$HOME/.cache}/herdr/agent-open.last"

fail() {
	rc=$1
	shift
	printf 'agent-open: %s\n' "$*" >&2
	"$herdr_bin" notification show 'Agent launcher' --body "$*" >/dev/null 2>&1 || :
	exit "$rc"
}

if [ "${1:-}" = last ]; then
	[ -r "$state" ] || fail 1 'No previous agent choice yet — pick one from prefix+y first.'
	# shellcheck disable=SC2046 # the state file holds three allowlisted words
	set -- $(cat "$state")
fi

[ "$#" -eq 3 ] || fail 64 'usage: agent-open.sh <right|down|tab> <agent> <run|off> | last'
placement=$1 agent=$2 record=$3

case "$placement" in right | down | tab) ;; *) fail 64 "unknown placement: $placement" ;; esac
case "$agent" in claude | codex | opencode | claude-copilot | codex-copilot) ;; *) fail 64 "unknown agent: $agent" ;; esac
case "$record" in run | off) ;; *) fail 64 "unknown record mode: $record" ;; esac
# SpecStory has no OpenCode provider — normalise instead of failing.
[ "$agent" = opencode ] && record=off

command -v "$herdr_bin" >/dev/null 2>&1 || fail 127 'herdr not found'
command -v jq >/dev/null 2>&1 || fail 127 'jq is required'

# Quick Actions export HERDR_PLUS_*; keybindings export HERDR_ACTIVE_PANE_*.
pane=${HERDR_PLUS_PANE_ID:-${HERDR_ACTIVE_PANE_ID:-${HERDR_PANE_ID:-}}}
[ -n "$pane" ] || pane=$("$herdr_bin" pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || :)
[ -n "$pane" ] || fail 1 'Could not find the source pane.'
info=$("$herdr_bin" pane get "$pane" 2>/dev/null || :)
# Without either env var (e.g. a detached type = "shell" bind that doesn't get
# them), $PWD would be the herdr server's dir — ask herdr for the live cwd.
cwd=${HERDR_PLUS_WORKDIR:-${HERDR_ACTIVE_PANE_CWD:-}}
[ -n "$cwd" ] || cwd=$(printf '%s' "$info" | jq -r '.result.pane | .foreground_cwd // .cwd // empty' 2>/dev/null || :)
[ -n "$cwd" ] || cwd=$PWD

mkdir -p "$(dirname "$state")"
printf '%s %s %s\n' "$placement" "$agent" "$record" >"$state"

launch="$agent $record"
full_rc=${HERDR_AGENT_FULL_RC:-0}
set -- --cwd "$cwd" --focus
[ "$full_rc" = 1 ] || set -- "$@" --env "HERDR_AGENT_LAUNCH=$launch"

if [ "$placement" = tab ]; then
	wid=$(printf '%s' "$info" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null || :)
	[ -n "$wid" ] && set -- --workspace "$wid" "$@"
	out=$("$herdr_bin" tab create --label "$agent" "$@") || fail 1 'herdr tab create failed'
	new=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
else
	out=$("$herdr_bin" pane split "$pane" --direction "$placement" "$@") || fail 1 'herdr pane split failed'
	new=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty')
fi

if [ "$full_rc" = 1 ]; then
	[ -n "$new" ] || fail 1 'herdr returned no pane id'
	"$herdr_bin" pane run "$new" "$HOME/.config/herdr/agent-run.sh $launch" >/dev/null || fail 1 'herdr pane run failed'
fi
