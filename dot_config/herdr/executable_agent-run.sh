#!/usr/bin/env bash
# ~/.config/herdr/agent-run.sh
# Source: dot_config/herdr/executable_agent-run.sh (managed by chezmoi)
#
# Run a coding agent with a LEAN environment — the fast path behind
# ~/.config/herdr/agent-open.sh. The HERDR_AGENT_LAUNCH guard at the top of
# ~/.zshrc / ~/.bashrc calls this BEFORE oh-my-zsh / ble.sh / starship / atuin
# load, as a child process, so nothing here leaks into the shell that the pane
# falls back to once the agent exits.
#
# Loaded: shared exports (PATH incl. ~/.local/bin, ~/.opencode/bin), the editor
# vars, the cwd's mise env, the POSIX + bash secrets files, and — for the copilot
# agents only — 43_copilot_proxy.sh, which defines claude/codex-copilot-once.
# NOT loaded: ~/.config/zsh/secrets.zsh (zsh syntax) and every interactive-only
# module. Need the exact interactive env? HERDR_AGENT_FULL_RC=1 on agent-open.sh.
#
# Usage: agent-run.sh <agent> <run|off>
#   agent: claude codex opencode claude-copilot codex-copilot
#   run = SpecStory live recording, off = direct

agent=${1:-} record=${2:-off}
case "$agent" in claude | codex | opencode | claude-copilot | codex-copilot) ;; *)
	printf 'agent-run: unknown agent: %s\n' "$agent" >&2
	exit 64
	;;
esac
case "$record" in run | off) ;; *)
	printf 'agent-run: unknown record mode: %s\n' "$record" >&2
	exit 64
	;;
esac

shell_dir="${XDG_CONFIG_HOME:-$HOME/.config}/shell"
for f in "$shell_dir/00_exports.sh" "$shell_dir/09_editor.sh" \
	"$HOME/.shellrc.secrets" "${XDG_CONFIG_HOME:-$HOME/.config}/bash/secrets.sh"; do
	# shellcheck disable=SC1090
	[ -r "$f" ] && . "$f"
done
if command -v mise >/dev/null 2>&1; then
	eval "$(mise env -s bash 2>/dev/null)"
fi

case "$agent" in
claude | codex)
	# Always name the provider: bare `specstory run` picks the alphabetically
	# first provider (pitfalls/specstory-run-default-agent-drift.md).
	if [ "$record" = run ]; then
		specstory run "$agent"
	else
		"$agent"
	fi
	;;
opencode) opencode ;;
claude-copilot | codex-copilot)
	# shellcheck disable=SC1091
	. "$shell_dir/43_copilot_proxy.sh" || exit 1
	"$agent-once" --specstory-mode "$record"
	;;
esac
