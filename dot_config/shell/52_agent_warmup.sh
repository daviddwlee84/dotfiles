# 52_agent_warmup.sh - Tyro-generated completion shared by zsh and bash.
# The generated files are caches, not chezmoi state; Tyro remains the CLI SSOT.

_agent_warmup_completion_shell() {
	if [ -n "${ZSH_VERSION:-}" ]; then
		printf '%s\n' zsh
	elif [ -n "${BASH_VERSION:-}" ]; then
		printf '%s\n' bash
	fi
}

_agent_warmup_load_completion() {
	command -v agent-warmup >/dev/null 2>&1 || return 0
	_aw_shell="$(_agent_warmup_completion_shell)"
	[ -n "$_aw_shell" ] || return 0
	_aw_cache_base="${XDG_CACHE_HOME:-$HOME/.cache}/agent-warmup/completions"
	if [ "$_aw_shell" = zsh ]; then
		_aw_cache="$_aw_cache_base/_agent-warmup"
	else
		_aw_cache="$_aw_cache_base/agent-warmup.bash"
	fi
	_aw_bin="$(command -v agent-warmup)"
	if [ ! -s "$_aw_cache" ] || [ "$_aw_bin" -nt "$_aw_cache" ]; then
		mkdir -p "$_aw_cache_base" || return 0
		_aw_tmp="$(mktemp "${TMPDIR:-/tmp}/agent-warmup-completion.XXXXXX")" || return 0
		if agent-warmup --tyro-print-completion "$_aw_shell" >"$_aw_tmp" 2>/dev/null; then
			mv "$_aw_tmp" "$_aw_cache"
		else
			rm -f "$_aw_tmp"
		fi
	fi
	if [ -r "$_aw_cache" ] && [ "$_aw_shell" = zsh ]; then
		fpath=("$_aw_cache_base" $fpath)
		autoload -Uz _agent-warmup
		compdef _agent-warmup agent-warmup
	elif [ -r "$_aw_cache" ]; then
		. "$_aw_cache"
	fi
	unset _aw_shell _aw_cache_base _aw_cache _aw_bin _aw_tmp
}

_agent_warmup_load_completion
unset -f _agent_warmup_load_completion 2>/dev/null || true
