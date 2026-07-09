# 10_aliases.sh - POSIX-portable aliases and functions for both shells.
# Sourced by ~/.zshrc and ~/.bashrc via load_modular_dir.
# Zsh-only helpers (zsh-profile, anything using `read -q` raw, ZLE widgets,
# OMZ-git-plugin shortcuts) stay in dot_config/zsh/10_aliases.zsh.

# --- Editor ----------------------------------------------------------------
alias v="nvim"

# --- VisiData --------------------------------------------------------------
# Force the pure-pyarrow ArrowSheet loader for any file. Escape hatch for
# .feather / .arrow files where the default PandasSheet path crashes on
# pandas StringDtype columns (`ValueError: Could not convert ... to NumPy
# dtype`). The companion dot_visidatarc reroutes .feather transparently, so
# this alias is mostly for: (a) hosts where the rc file hasn't been deployed
# yet, (b) explicit/debug invocation, (c) .arrow files VisiData mis-detects.
# Full diagnosis: pitfalls/visidata-feather-stringdtype-numpy-dtype.md.
alias vd-arrow='visidata -f arrow'

# Open VisiData in read-only mode — safe for inspecting "raw data" files
# you don't want to accidentally overwrite. Implementation note:
# `--readonly` is an optalias for `--overwrite=n` (visidata/modify.py:11),
# which causes `confirmOverwrite()` to `fail('overwrite disabled')` instead
# of saving. In-memory edits in the sheet are still ALLOWED (the deferred
# add/mod/delete tracking still works for prototyping), but you cannot
# `Ctrl+S` or `g Ctrl+S` them back to the source file. Useful when:
#  - inspecting .feather / .parquet inputs from upstream pipelines
#  - opening logs / CSVs received from colleagues
#  - any time you want belt-and-suspenders over VisiData's built-in
#    "never auto-save" guarantee
# (VisiData NEVER auto-saves regardless; this just blocks the save path
# even if your finger slips on g Ctrl+S.)
alias vd-ro='visidata --readonly'

# --- Keybindings cheatsheet ------------------------------------------------
# Static viewer for ~/.config/docs/shells/keybindings.md (the same data
# source that the `keys-picker` ZLE widget on Alt+/ reads). Useful on bash
# (no ZLE port) and inside non-interactive shells. Prefers `tv keybindings`
# (television channel) → `bat` → `cat` in that order.
bindings() {
	doc="${HOME}/.config/docs/shells/keybindings.md"
	if [ ! -f "$doc" ]; then
		echo "bindings: $doc not found (chezmoi apply needed?)" >&2
		unset doc
		return 1
	fi
	if command -v tv >/dev/null 2>&1 &&
		[ -f "${HOME}/.config/television/cable/keybindings.toml" ]; then
		tv keybindings
	elif command -v bat >/dev/null 2>&1; then
		bat --style=plain --paging=always "$doc"
	else
		"${PAGER:-less}" "$doc" 2>/dev/null || cat "$doc"
	fi
	unset doc
}

# --- tmux restore cleanup --------------------------------------------------
# Intentional "I am done" exits should clear tmux-resurrect's `last` pointer so
# tmux-continuum doesn't resurrect every just-killed session on the next start.
alias tmux-kill-clean='$HOME/.config/tmux/kill-server-clean.sh'
alias tmux-forget-last='$HOME/.config/tmux/resurrect-forget.sh'

# --- run-for: time-box any long-running / infinite command -----------------
# Run CMD for at most DURATION, then send SIGINT (same as Ctrl-C) so a script's
# `trap INT` summary still prints; escalate to SIGKILL after a grace if the
# command ignores the interrupt. Wraps GNU timeout — gtimeout on macOS, timeout
# on Linux (both shipped by the coreutils install in the devtools ansible role).
#
# Usage:  run-for DURATION CMD [ARGS...]
#   DURATION takes GNU timeout suffixes: 30s, 5m, 2h, 1d, or bare seconds.
#   RUN_FOR_SIGNAL      signal sent on expiry (default INT)
#   RUN_FOR_KILL_AFTER  grace before SIGKILL (default 5s)
# Exit status: 124 = the time-box was hit (command still running); otherwise
#   the command's own exit status passes through.
# Examples:
#   run-for 5m ping-monitor --gateway 10
#   run-for 30s ./some-infinite-loop.sh
run-for() {
	[ "$#" -lt 2 ] && {
		echo "Usage: run-for DURATION CMD [ARGS...]" >&2
		return 2
	}
	local to dur
	to="$(command -v gtimeout || command -v timeout)" || {
		echo "run-for: GNU timeout not found (install coreutils)" >&2
		return 127
	}
	dur="$1"
	shift
	"$to" --signal="${RUN_FOR_SIGNAL:-INT}" --kill-after="${RUN_FOR_KILL_AFTER:-5s}" "$dur" "$@"
}

# --- Reload shell config (source-rc / reload) ------------------------------
# Re-source the CURRENT shell's rc entry point in place, so a running session
# picks up new aliases/functions after `chezmoi apply` — without exec'ing a
# fresh login shell (that heavier, guaranteed-clean path is `cas`/`cau` in
# 99_chezmoi_reload.sh). Dispatches on the live interpreter
# ($ZSH_VERSION/$BASH_VERSION), NOT $SHELL (which lags `chsh` until next login).
# `function` keyword (not `name()`) is deliberate: source-rc re-parses this file
# on every call, so its definition must be immune to the ALIAS_FUNC_DEF
# re-source `parse error near \`()'` — see
# pitfalls/zsh-parse-error-on-resource-after-bw-completion-aliased-name.md.
# Re-sourcing only *redefines* source-rc (never re-calls it → no recursion) and
# inherits the same caveats as a manual `source ~/.zshrc`.
function source-rc {
	if [ -n "${ZSH_VERSION:-}" ]; then
		_rc="$HOME/.zshrc"
	elif [ -n "${BASH_VERSION:-}" ]; then
		_rc="$HOME/.bashrc"
	else
		printf 'source-rc: unsupported shell (need zsh or bash)\n' >&2
		return 1
	fi
	if [ ! -f "$_rc" ]; then
		printf 'source-rc: %s not found (run chezmoi apply first?)\n' "$_rc" >&2
		unset _rc
		return 1
	fi
	printf 'source-rc: reloading %s\n' "$_rc"
	# shellcheck source=/dev/null
	. "$_rc"
	# oh-my-zsh's lib/key-bindings.zsh runs `bindkey -e` on EVERY source, and
	# zsh-vi-mode's re-entrancy guard (`command -v zvm_version && return` at the
	# top of the plugin) makes it skip re-init on re-source — so the main keymap
	# silently reverts to emacs and vim mode never returns (ZVM_INIT_DONE stays
	# true, so the pending precmd zvm_init early-returns forever). Force a
	# one-shot in-place re-init, which also replays zvm_after_init (fzf/atuin/
	# aisuggest/keys-picker rebinds). No-op when enableVimMode=false or the
	# plugin isn't loaded (zvm_init absent). POSIX-safe: the ZSH_VERSION guard
	# keeps bash out of the zsh-only branch. See
	# pitfalls/zsh-vim-mode-lost-after-source-rc.md.
	if [ -n "${ZSH_VERSION:-}" ] && command -v zvm_init >/dev/null 2>&1; then
		ZVM_INIT_DONE=false
		zvm_init
	fi
	unset _rc
}
alias reload='source-rc'

# --- Chezmoi ---------------------------------------------------------------
# https://www.chezmoi.io/user-guide/frequently-asked-questions/design/#why-does-chezmoi-cd-spawn-a-shell-instead-of-just-changing-directory
chezmoi-cd() {
	cd "$(chezmoi source-path)" || return 1
}

# --- Git shortcuts ---------------------------------------------------------
# NOTE: gcam (git commit --all --message), gca (git commit --verbose --all),
# gca! (... --amend), gcan! (... --amend --no-edit) are provided by
# oh-my-zsh's git plugin and oh-my-bash's git plugin (parity).

# Amend last commit message (pass new message as argument)
gcam-amend() {
	[ -z "$1" ] && {
		echo "Usage: gcam-amend <new message>"
		return 1
	}
	git commit --amend -m "$1"
}

# Undo last commit → back to staged, print the undone commit message
gundo() {
	msg="$(git log -1 --pretty=%B)" || return 1
	git reset --soft HEAD~1 && printf 'Undone commit:\n  %s\n' "$msg"
	unset msg
}

# Show commits on current branch not yet pushed to origin/master
alias glop='git log --oneline origin/master..HEAD'

# --- nvm lazy-load ---------------------------------------------------------
# Load NVM for current session (when needed for version switching)
alias load-nvm='export LOAD_NVM=1 && . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && . "${NVM_DIR:-$HOME/.nvm}/bash_completion" && echo "nvm loaded: $(nvm current)"'

# --- bw completion regen ---------------------------------------------------
# Note: writes per-shell completion to its native cache. Bash equivalent
# lives in dot_config/bash/10_aliases.bash.
function bw-update-completion {
	if [ -n "$ZSH_VERSION" ]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh" &&
			bw completion --shell zsh >"${XDG_CACHE_HOME:-$HOME/.cache}/zsh/bw_completion.zsh" 2>/dev/null &&
			echo "bw completion cache updated (zsh)"
	elif [ -n "$BASH_VERSION" ]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/bash" &&
			bw completion --shell bash >"${XDG_CACHE_HOME:-$HOME/.cache}/bash/bw_completion.bash" 2>/dev/null &&
			echo "bw completion cache updated (bash)"
	fi
}

# --- marimo / thefuck completion regen -------------------------------------
# Same caching strategy as bw-update-completion (above). The mtime check on
# the binary inside dot_config/shell/{29_marimo.sh,27_thefuck.sh} catches
# `uv tool upgrade marimo` / `brew upgrade thefuck` automatically; these
# helpers exist for edge cases (in-place upgrade where mtime doesn't bump,
# corrupted cache, manual debugging). `function name { … }` syntax (not POSIX
# `name()`) avoids the alias-collision footgun documented in
# pitfalls/zsh-parse-error-on-resource-after-bw-completion-aliased-name.md.
function marimo-update-completion {
	command -v marimo >/dev/null 2>&1 || {
		echo "marimo-update-completion: marimo not installed" >&2
		return 1
	}
	if [ -n "$ZSH_VERSION" ]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh" &&
			_MARIMO_COMPLETE=zsh_source marimo >"${XDG_CACHE_HOME:-$HOME/.cache}/zsh/marimo_completion.zsh" 2>/dev/null &&
			echo "marimo completion cache updated (zsh)"
	elif [ -n "$BASH_VERSION" ]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/bash" &&
			_MARIMO_COMPLETE=bash_source marimo >"${XDG_CACHE_HOME:-$HOME/.cache}/bash/marimo_completion.bash" 2>/dev/null &&
			echo "marimo completion cache updated (bash)"
	fi
}

function thefuck-update-completion {
	command -v thefuck >/dev/null 2>&1 || {
		echo "thefuck-update-completion: thefuck not installed" >&2
		return 1
	}
	if [ -n "$ZSH_VERSION" ]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh" &&
			thefuck --alias >"${XDG_CACHE_HOME:-$HOME/.cache}/zsh/thefuck_alias.zsh" 2>/dev/null &&
			echo "thefuck alias cache updated (zsh)"
	elif [ -n "$BASH_VERSION" ]; then
		mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/bash" &&
			thefuck --alias >"${XDG_CACHE_HOME:-$HOME/.cache}/bash/thefuck_alias.bash" 2>/dev/null &&
			echo "thefuck alias cache updated (bash)"
	fi
}

# --- mi-dhcp-bind (tyro) completion regen ----------------------------------
# Force-regenerate the lazy-autoload completion file used by 46_mi_dhcp_bind.sh
# (sister to mi-router-update-completion below; mi-dhcp-bind is the WRITE tool).
function mi-dhcp-bind-update-completion {
	command -v mi-dhcp-bind >/dev/null 2>&1 || {
		echo "mi-dhcp-bind-update-completion: mi-dhcp-bind not installed" >&2
		return 1
	}
	if [ -n "$ZSH_VERSION" ]; then
		local _tmp
		_tmp=$(mktemp)
		if mi-dhcp-bind --tyro-write-completion zsh "$_tmp" >/dev/null 2>&1; then
			mkdir -p "${HOME}/.zfunc"
			{ echo "#compdef mi-dhcp-bind"; tail -n +2 "$_tmp"; } >"${HOME}/.zfunc/_mi-dhcp-bind" &&
				echo "mi-dhcp-bind completion cache updated (zsh: ~/.zfunc/_mi-dhcp-bind)"
		fi
		rm -f "$_tmp"
	elif [ -n "$BASH_VERSION" ]; then
		local _bashdir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
		mkdir -p "$_bashdir" &&
			mi-dhcp-bind --tyro-write-completion bash "$_bashdir/mi-dhcp-bind" >/dev/null 2>&1 &&
			echo "mi-dhcp-bind completion cache updated (bash: $_bashdir/mi-dhcp-bind)"
	fi
}

# --- mi-router (tyro) completion regen -------------------------------------
# Force-regenerate the lazy-autoload completion file used by 47_mi_router.sh.
# Useful after a tyro upgrade where mi-router's binary mtime didn't change
# but the completion grammar did (uncommon).
function mi-router-update-completion {
	command -v mi-router >/dev/null 2>&1 || {
		echo "mi-router-update-completion: mi-router not installed" >&2
		return 1
	}
	if [ -n "$ZSH_VERSION" ]; then
		local _tmp
		_tmp=$(mktemp)
		if mi-router --tyro-write-completion zsh "$_tmp" >/dev/null 2>&1; then
			mkdir -p "${HOME}/.zfunc"
			# Rewrite tyro's `#compdef <fullpath>` to the short name so
			# `mi-router<TAB>` (not full path) triggers compinit.
			{ echo "#compdef mi-router"; tail -n +2 "$_tmp"; } >"${HOME}/.zfunc/_mi-router" &&
				echo "mi-router completion cache updated (zsh: ~/.zfunc/_mi-router)"
		fi
		rm -f "$_tmp"
	elif [ -n "$BASH_VERSION" ]; then
		local _bashdir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
		mkdir -p "$_bashdir" &&
			mi-router --tyro-write-completion bash "$_bashdir/mi-router" >/dev/null 2>&1 &&
			echo "mi-router completion cache updated (bash: $_bashdir/mi-router)"
	fi
}

# --- reyee (tyro) completion regen ----------------------------------------
# Force-regenerate the lazy-autoload completion file used by 48_reyee.sh
# (sister to mi-router-update-completion above).
function reyee-update-completion {
	command -v reyee >/dev/null 2>&1 || {
		echo "reyee-update-completion: reyee not installed" >&2
		return 1
	}
	if [ -n "$ZSH_VERSION" ]; then
		local _tmp
		_tmp=$(mktemp)
		if reyee --tyro-write-completion zsh "$_tmp" >/dev/null 2>&1; then
			mkdir -p "${HOME}/.zfunc"
			{ echo "#compdef reyee"; tail -n +2 "$_tmp"; } >"${HOME}/.zfunc/_reyee" &&
				echo "reyee completion cache updated (zsh: ~/.zfunc/_reyee)"
		fi
		rm -f "$_tmp"
	elif [ -n "$BASH_VERSION" ]; then
		local _bashdir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
		mkdir -p "$_bashdir" &&
			reyee --tyro-write-completion bash "$_bashdir/reyee" >/dev/null 2>&1 &&
			echo "reyee completion cache updated (bash: $_bashdir/reyee)"
	fi
}

# --- Ghostty terminfo install on remote SSH host ---------------------------
# Fixes character-rendering issues when SSH'ing into a fresh host from
# Ghostty/cmux/tmux. Usage: ghostty-ssh-terminfo <ssh-host>
ghostty-ssh-terminfo() {
	host="$1"

	if [ -z "$host" ]; then
		echo "Usage: ghostty-ssh-terminfo <ssh-host>" >&2
		return 1
	fi

	if ! command -v infocmp >/dev/null 2>&1; then
		echo "ghostty-ssh-terminfo: local 'infocmp' not found" >&2
		return 1
	fi

	if ! infocmp -x xterm-ghostty >/dev/null 2>&1; then
		echo "ghostty-ssh-terminfo: local terminfo 'xterm-ghostty' not found" >&2
		return 1
	fi

	if ! infocmp -x xterm-ghostty |
		ssh "$host" '
          set -e
          if ! command -v tic >/dev/null 2>&1; then
            echo "remote: tic not found" >&2
            exit 127
          fi
          mkdir -p "$HOME/.terminfo"
          TERMINFO="$HOME/.terminfo" tic -x -
        ' 2> >(grep -Fv "older tic versions may treat the description field as an alias" >&2); then
		echo "ghostty-ssh-terminfo: failed to install on $host" >&2
		return 1
	fi

	echo "Installed xterm-ghostty terminfo on $host (in ~/.terminfo)"
}

# --- Homebrew mirror switch (GFW workaround) -------------------------------
# Default baseline (BFSU) is set in 00_exports.sh.tmpl; use this only when a
# mirror misbehaves. Benchmarks (2026-07, CN network): BFSU fastest overall
# (git 1.1s, bottles 31 MB/s) > USTC (git 1.0s, 11 MB/s) > Aliyun (git BROKEN —
# upload-pack hangs — bottles fine) > TUNA (git timeout, both slow).
#
# NB: this intentionally does NOT touch HOMEBREW_CORE_GIT_REMOTE — it *unsets*
# it. In Homebrew 4.x the JSON API (HOMEBREW_API_DOMAIN) is the source of truth;
# setting HOMEBREW_CORE_GIT_REMOTE forces a full ~1 GB homebrew-core git clone
# on the next `brew update` for zero benefit. See
# pitfalls/homebrew-aliyun-brew-git-hang-core-clone-bloat.md.
# Usage: brew-mirror                    # show current endpoints
#        brew-mirror {bfsu|ustc|aliyun|tuna}
brew-mirror() {
	mirror="${1:-}"
	case "$mirror" in
	bfsu)
		api="https://mirrors.bfsu.edu.cn/homebrew-bottles/api"
		bottles="https://mirrors.bfsu.edu.cn/homebrew-bottles"
		brew_git="https://mirrors.bfsu.edu.cn/git/homebrew/brew.git"
		;;
	ustc)
		api="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
		bottles="https://mirrors.ustc.edu.cn/homebrew-bottles"
		brew_git="https://mirrors.ustc.edu.cn/brew.git"
		;;
	aliyun)
		# Bottles/API only — Aliyun's brew.git upload-pack hangs, so keep the
		# git remote on the current value rather than switching it to Aliyun.
		api="https://mirrors.aliyun.com/homebrew-bottles/api"
		bottles="https://mirrors.aliyun.com/homebrew-bottles"
		brew_git="${HOMEBREW_BREW_GIT_REMOTE:-https://mirrors.bfsu.edu.cn/git/homebrew/brew.git}"
		echo "brew-mirror: note — Aliyun brew.git is broken; keeping git remote at $brew_git" >&2
		;;
	tuna)
		api="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
		bottles="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
		brew_git="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
		;;
	"")
		echo "Current Homebrew mirror env vars:"
		echo "  HOMEBREW_API_DOMAIN      = ${HOMEBREW_API_DOMAIN:-<unset>}"
		echo "  HOMEBREW_BOTTLE_DOMAIN   = ${HOMEBREW_BOTTLE_DOMAIN:-<unset>}"
		echo "  HOMEBREW_BREW_GIT_REMOTE = ${HOMEBREW_BREW_GIT_REMOTE:-<unset>}"
		echo "  HOMEBREW_CORE_GIT_REMOTE = ${HOMEBREW_CORE_GIT_REMOTE:-<unset>} (should be unset — API mode)"
		echo
		echo "Usage: brew-mirror {bfsu|ustc|aliyun|tuna}"
		return 0
		;;
	*)
		echo "brew-mirror: unknown mirror '$mirror'" >&2
		echo "Usage: brew-mirror {bfsu|ustc|aliyun|tuna}" >&2
		return 1
		;;
	esac

	export HOMEBREW_API_DOMAIN="$api"
	export HOMEBREW_BOTTLE_DOMAIN="$bottles"
	export HOMEBREW_BREW_GIT_REMOTE="$brew_git"
	# Never set HOMEBREW_CORE_GIT_REMOTE — it forces a ~1 GB homebrew-core clone
	# in API mode. Clear any inherited value so `brew update` stays lean.
	unset HOMEBREW_CORE_GIT_REMOTE

	# Rewrite origin of the brew.git clone (always a real clone). Do NOT rewrite
	# homebrew/core: in API mode it's an ~8 KB stub; if a previous misconfig left
	# a full git clone, untap it to restore lean API mode instead of re-pointing.
	if command -v brew >/dev/null 2>&1; then
		brew_repo="$(brew --repo 2>/dev/null)"
		[ -n "$brew_repo" ] && [ -d "$brew_repo/.git" ] &&
			git -C "$brew_repo" remote set-url origin "$brew_git" 2>/dev/null
		core_repo="$(brew --repo homebrew/core 2>/dev/null)"
		if [ -n "$core_repo" ] && [ -d "$core_repo/.git" ]; then
			# >100 MB ⇒ it's a full clone, not the API stub → untap to slim down.
			core_kb="$(du -sk "$core_repo/.git" 2>/dev/null | cut -f1)"
			if [ -n "$core_kb" ] && [ "$core_kb" -gt 102400 ]; then
				echo "brew-mirror: found ~$((core_kb / 1024)) MB homebrew/core git clone; untapping to restore API mode" >&2
				HOMEBREW_NO_AUTO_UPDATE=1 brew untap homebrew/core >/dev/null 2>&1
			fi
		fi
	fi

	echo "brew-mirror: switched to $mirror"
	echo "  Run 'brew update' to re-sync indexes."
	unset mirror api bottles brew_git brew_repo core_repo core_kb
}

# --- claude-plans-here -----------------------------------------------------
# Scaffold or update project-local .claude/settings.json so Claude Code's
# /plan files land in ./.claude/plans/ (kept inside the repo) instead of the
# user-global plansDirectory. Pairs well with the agent-history-hygiene skill,
# which can then redact + commit the plan files alongside the diff.
#
# Also offers to import "orphan" plans — plans previously written under the
# global ~/.claude/plans/ that belong to this project. Detection: scan
# ~/.claude/projects/<encoded-cwd>/*.jsonl (where Claude Code logs sessions
# per cwd; encoding maps '/' and '.' to '-') for authoritative write records:
# Write/Edit/MultiEdit tool_use file paths, newer toolUseResult.filePath
# records, and ExitPlanMode planFilePath fields. This avoids false positives
# from sessions that merely *mentioned* a plan path in conversation.
#
# Usage: claude-plans-here [-f] [-y]
#   -f   auto-yes the settings.json merge prompt
#   -y   auto-yes the orphan-plan copy prompt
claude-plans-here() {
	force_settings=0
	force_orphans=0
	while [ $# -gt 0 ]; do
		case "$1" in
		-f) force_settings=1 ;;
		-y) force_orphans=1 ;;
		-h | --help)
			echo "Usage: claude-plans-here [-f] [-y]"
			echo "  -f   auto-yes the settings.json merge prompt"
			echo "  -y   auto-yes the orphan-plan copy prompt"
			return 0
			;;
		*)
			echo "claude-plans-here: unknown flag '$1'" >&2
			return 1
			;;
		esac
		shift
	done

	target=".claude/settings.json"
	mkdir -p .claude/plans

	if [ ! -e "$target" ]; then
		cat >"$target" <<'EOF'
{
  "plansDirectory": "./.claude/plans"
}
EOF
		echo "Wrote $PWD/$target"
	else
		if ! command -v jq >/dev/null 2>&1; then
			echo "claude-plans-here: jq required to merge into existing $target" >&2
			return 1
		fi

		ans=y
		if [ "$force_settings" = "0" ]; then
			printf '%s exists. Merge plansDirectory into it? [y/N] ' "$target"
			read -r ans
		fi

		case "$ans" in
		y | Y | yes | YES | Yes)
			tmp="$(mktemp)" || return 1
			if jq --arg p "./.claude/plans" '. + {plansDirectory: $p}' "$target" >"$tmp"; then
				mv "$tmp" "$target"
				echo "Merged plansDirectory into $PWD/$target"
			else
				rm -f "$tmp"
				echo "claude-plans-here: jq failed; $target unchanged" >&2
				return 1
			fi
			;;
		esac
	fi

	_claude_plans_here_import_orphans "$force_orphans"
	unset force_settings force_orphans target ans tmp
}

# Internal: scan ~/.claude/projects/<encoded-cwd|encoded-git-root>/*.jsonl
# for authoritative records that wrote into ~/.claude/plans/, list the ones
# still living in the global dir and not yet copied locally, prompt y/N.
_claude_plans_here_import_orphans() {
	force="$1"
	global_plans="$HOME/.claude/plans"
	[ -d "$global_plans" ] || return 0

	# Claude Code projects/ encoding: replace each '/' and '.' with '-'.
	enc_cwd="$(printf '%s' "$PWD" | tr '/.' '--')"
	enc_root=""
	if command -v git >/dev/null 2>&1; then
		groot="$(git rev-parse --show-toplevel 2>/dev/null)"
		if [ -n "$groot" ] && [ "$groot" != "$PWD" ]; then
			enc_root="$(printf '%s' "$groot" | tr '/.' '--')"
		fi
	fi

	proj_dirs=""
	[ -d "$HOME/.claude/projects/$enc_cwd" ] && proj_dirs="$HOME/.claude/projects/$enc_cwd"
	[ -n "$enc_root" ] && [ -d "$HOME/.claude/projects/$enc_root" ] &&
		proj_dirs="${proj_dirs}
$HOME/.claude/projects/$enc_root"
	[ -z "$proj_dirs" ] && return 0

	jsonl_files="$(
		printf '%s\n' "$proj_dirs" | while IFS= read -r d; do
			[ -n "$d" ] || continue
			find "$d" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null
		done
	)"
	[ -z "$jsonl_files" ] && return 0

	matches="$(_claude_plans_here_find_plan_paths "$global_plans" "$jsonl_files")"
	[ -z "$matches" ] && return 0

	candidates=""
	count=0
	while IFS= read -r m; do
		[ -f "$m" ] || continue
		base="${m##*/}"
		[ -e ".claude/plans/$base" ] && continue
		candidates="$candidates
$m"
		count=$((count + 1))
	done <<EOF
$matches
EOF
	[ "$count" = 0 ] && return 0

	echo
	echo "Found $count orphan plan(s) in ~/.claude/plans/ linked to this project:"
	printf '%s\n' "$candidates" | while IFS= read -r m; do
		[ -z "$m" ] && continue
		printf '  - %s\n' "${m#$HOME/}"
	done

	ans=y
	if [ "$force" = "0" ]; then
		printf 'Copy them into ./.claude/plans/ (originals kept)? [y/N] '
		read -r ans
	fi
	case "$ans" in
	y | Y | yes | YES | Yes) ;;
	*) return 0 ;;
	esac

	copied=0
	while IFS= read -r m; do
		[ -z "$m" ] && continue
		cp -n "$m" .claude/plans/ 2>/dev/null && copied=$((copied + 1))
	done <<EOF
$candidates
EOF
	echo "Copied plan(s) into $PWD/.claude/plans/"
	unset force global_plans enc_cwd enc_root groot proj_dirs jsonl_files matches candidates count m base ans copied
}

_claude_plans_here_find_plan_paths() {
	global_plans="$1"
	jsonl_files="$2"

	if command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$jsonl_files" | while IFS= read -r f; do
			[ -r "$f" ] || continue
			jq -r --arg gp "$global_plans" '
				def planpath:
					select(type == "string")
					| select(startswith($gp + "/") and test("\\.md$"));
				[
					(.message.content[]?
						| select(.type == "tool_use")
						| select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
						| (.input.file_path?, .input.filePath?, .input.path?)),
					(.message.content[]?
						| select(.type == "tool_use" and .name == "ExitPlanMode")
						| (.input.planFilePath?, .input.plan_file_path?)),
					(.toolUseResult.filePath?, .toolUseResult.file_path?, .toolUseResult.path?),
					(.toolUseResult.planFilePath?, .toolUseResult.plan_file_path?),
					(.planFilePath?, .plan_file_path?)
				]
				| .[]?
				| planpath
			' "$f" 2>/dev/null
		done | sort -u
	else
		# Cold-start fallback for hosts without jq. Less precise than the JSON
		# parser, but still scoped to lines that contain write/result markers.
		re_prefix="$(printf '%s' "$global_plans" | sed 's/[.[\*^$()+?{|]/\\&/g')"
		printf '%s\n' "$jsonl_files" | while IFS= read -r f; do
			[ -r "$f" ] || continue
			grep -hE '"name"[[:space:]]*:[[:space:]]*"(Write|Edit|MultiEdit)"|"toolUseResult"|"planFilePath"' "$f" 2>/dev/null
		done |
			grep -oE "${re_prefix}/[A-Za-z0-9_.+-]+\.md" |
			sort -u
	fi

	unset global_plans jsonl_files f re_prefix
}
