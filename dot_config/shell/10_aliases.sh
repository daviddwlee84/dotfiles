# 10_aliases.sh - POSIX-portable aliases and functions for both shells.
# Sourced by ~/.zshrc and ~/.bashrc via load_modular_dir.
# Zsh-only helpers (zsh-profile, anything using `read -q` raw, ZLE widgets,
# OMZ-git-plugin shortcuts) stay in dot_config/zsh/10_aliases.zsh.

# --- Editor ----------------------------------------------------------------
alias v="nvim"

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
# Default baseline (Aliyun) is set in 00_exports.sh.tmpl; use this only when
# a mirror misbehaves.
# Usage: brew-mirror                    # show current endpoints
#        brew-mirror {aliyun|ustc|bfsu|tuna}
brew-mirror() {
	mirror="${1:-}"
	case "$mirror" in
	aliyun)
		api="https://mirrors.aliyun.com/homebrew-bottles/api"
		bottles="https://mirrors.aliyun.com/homebrew-bottles"
		brew_git="https://mirrors.aliyun.com/homebrew/brew.git"
		core_git="https://mirrors.aliyun.com/homebrew/homebrew-core.git"
		;;
	ustc)
		api="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
		bottles="https://mirrors.ustc.edu.cn/homebrew-bottles"
		brew_git="https://mirrors.ustc.edu.cn/brew.git"
		core_git="https://mirrors.ustc.edu.cn/homebrew-core.git"
		;;
	bfsu)
		api="https://mirrors.bfsu.edu.cn/homebrew-bottles/api"
		bottles="https://mirrors.bfsu.edu.cn/homebrew-bottles"
		brew_git="https://mirrors.bfsu.edu.cn/git/homebrew/brew.git"
		core_git="https://mirrors.bfsu.edu.cn/git/homebrew/homebrew-core.git"
		;;
	tuna)
		api="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
		bottles="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
		brew_git="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
		core_git="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
		;;
	"")
		echo "Current Homebrew mirror env vars:"
		echo "  HOMEBREW_API_DOMAIN      = ${HOMEBREW_API_DOMAIN:-<unset>}"
		echo "  HOMEBREW_BOTTLE_DOMAIN   = ${HOMEBREW_BOTTLE_DOMAIN:-<unset>}"
		echo "  HOMEBREW_BREW_GIT_REMOTE = ${HOMEBREW_BREW_GIT_REMOTE:-<unset>}"
		echo "  HOMEBREW_CORE_GIT_REMOTE = ${HOMEBREW_CORE_GIT_REMOTE:-<unset>}"
		echo
		echo "Usage: brew-mirror {aliyun|ustc|bfsu|tuna}"
		return 0
		;;
	*)
		echo "brew-mirror: unknown mirror '$mirror'" >&2
		echo "Usage: brew-mirror {aliyun|ustc|bfsu|tuna}" >&2
		return 1
		;;
	esac

	export HOMEBREW_API_DOMAIN="$api"
	export HOMEBREW_BOTTLE_DOMAIN="$bottles"
	export HOMEBREW_BREW_GIT_REMOTE="$brew_git"
	export HOMEBREW_CORE_GIT_REMOTE="$core_git"

	# Rewrite origin of existing clones. `brew --repo homebrew/core` only exists
	# if the user has tapped homebrew/core (optional in Homebrew 4.x — API/JSON
	# is default), so guard on .git presence.
	if command -v brew >/dev/null 2>&1; then
		brew_repo="$(brew --repo 2>/dev/null)"
		[ -n "$brew_repo" ] && [ -d "$brew_repo/.git" ] &&
			git -C "$brew_repo" remote set-url origin "$brew_git" 2>/dev/null
		core_repo="$(brew --repo homebrew/core 2>/dev/null)"
		[ -n "$core_repo" ] && [ -d "$core_repo/.git" ] &&
			git -C "$core_repo" remote set-url origin "$core_git" 2>/dev/null
	fi

	echo "brew-mirror: switched to $mirror"
	echo "  Run 'brew update' to re-sync indexes."
	unset mirror api bottles brew_git core_git brew_repo core_repo
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
# per cwd; encoding maps '/' and '.' to '-') for Write/Edit tool_use entries
# whose file_path points into ~/.claude/plans/. This avoids false positives
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
# for Write/Edit tool_use entries that wrote into ~/.claude/plans/, list the
# ones still living in the global dir and not yet copied locally, prompt y/N.
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
		proj_dirs="$proj_dirs $HOME/.claude/projects/$enc_root"
	[ -z "$proj_dirs" ] && return 0

	jsonl_files=""
	for d in $proj_dirs; do
		for f in "$d"/*.jsonl; do
			[ -r "$f" ] || continue
			jsonl_files="$jsonl_files $f"
		done
	done
	[ -z "$jsonl_files" ] && return 0

	# Two-stage filter: only lines containing a Write/Edit tool_use, then
	# extract any plan-path within them. Authoritative — avoids matching plan
	# paths that merely appeared in user/assistant text.
	re_prefix="$(printf '%s' "$global_plans" | sed 's/[.[\*^$()+?{|]/\\&/g')"
	matches="$(
		# shellcheck disable=SC2086
		grep -hE '"name":"(Write|Edit)"' $jsonl_files 2>/dev/null |
			grep -oE "${re_prefix}/[A-Za-z0-9_.+-]+\.md" |
			sort -u
	)"
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
	printf '%s\n' "$candidates" | while IFS= read -r m; do
		[ -z "$m" ] && continue
		cp -n "$m" .claude/plans/ 2>/dev/null && copied=$((copied + 1))
	done
	echo "Copied plan(s) into $PWD/.claude/plans/"
	unset force global_plans enc_cwd enc_root proj_dirs jsonl_files re_prefix matches candidates count m base ans copied
}
