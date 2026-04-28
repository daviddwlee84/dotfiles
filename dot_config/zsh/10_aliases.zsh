# 10_aliases.zsh - Common aliases

# --- Your existing aliases ---
alias v="nvim"

# --- Suggested aliases (uncomment to enable) ---
# Navigation
# alias ..="cd .."
# alias ...="cd ../.."
# alias ....="cd ../../.."

# List files (current managed by ./tools/26_esa.zsh)
# alias l="ls -lah"
# alias la="ls -lAh"
# alias ll="ls -lh"

# Safety
# alias rm="rm -i"
# alias cp="cp -i"
# alias mv="mv -i"

# Editor
# alias vi="nvim"
# alias vim="nvim"

# Modern replacements (if installed)
# command -v eza &>/dev/null && alias ls="eza"
# command -v bat &>/dev/null && alias cat="bat"

# Chezmoi
# https://www.chezmoi.io/user-guide/frequently-asked-questions/design/#why-does-chezmoi-cd-spawn-a-shell-instead-of-just-changing-directory
chezmoi-cd() {
  cd $(chezmoi source-path)
}

# Git shortcuts
# NOTE: gcam (git commit --all --message) is provided by oh-my-zsh git plugin
# NOTE: gca (git commit --verbose --all) is provided by oh-my-zsh git plugin
# NOTE: gca! (git commit --verbose --all --amend) is provided by oh-my-zsh git plugin
# NOTE: gcan! (git commit --verbose --all --no-edit --amend) is provided by oh-my-zsh git plugin

# Amend last commit message (pass new message as argument)
gcam-amend() {
  [[ -z "$1" ]] && { echo "Usage: gcam-amend <new message>"; return 1; }
  git commit --amend -m "$1"
}

# Undo last commit → back to staged, print the undone commit message
gundo() {
  local msg
  msg="$(git log -1 --pretty=%B)" || return 1
  git reset --soft HEAD~1 && echo "Undone commit:\n  $msg"
}
# Show commits on current branch not yet pushed to origin/master
alias glop='git log --oneline origin/master..HEAD'

# Zsh startup profiling
alias zsh-profile='ZSH_PROF=1 zsh -i -c exit'

# Load NVM for current session (when needed for version switching)
alias load-nvm='export LOAD_NVM=1 && source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && source "${NVM_DIR:-$HOME/.nvm}/bash_completion" && echo "nvm loaded: $(nvm current)"'

# Regenerate cached bw completion (run after updating bw CLI)
alias bw-update-completion='mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh" && bw completion --shell zsh > "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/bw_completion.zsh" 2>/dev/null && echo "bw completion cache updated"'

# Install Ghostty terminfo on a remote host (unprivileged, into ~/.terminfo).
# Fixes character-rendering issues when SSH'ing into a fresh host from Ghostty/cmux/tmux.
# Usage: ghostty-ssh-terminfo <ssh-host>
ghostty-ssh-terminfo() {
  emulate -L zsh
  setopt pipefail

  local host="$1"

  if [[ -z "$host" ]]; then
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

  if ! infocmp -x xterm-ghostty \
      | ssh "$host" '
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

# Switch Homebrew mirror on-the-fly (GFW workaround). Updates env vars AND
# rewrites existing clone git remotes in-place, so a follow-up `brew update`
# uses the new mirror without reinstalling. Default baseline (Aliyun) is set
# in 00_exports.zsh.tmpl; use this only when a mirror misbehaves.
# Usage: brew-mirror                    # show current endpoints
#        brew-mirror {aliyun|ustc|bfsu|tuna}
brew-mirror() {
  emulate -L zsh
  local mirror="${1:-}"
  local api bottles brew_git core_git
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
    local brew_repo core_repo
    brew_repo="$(brew --repo 2>/dev/null)"
    [[ -n "$brew_repo" && -d "$brew_repo/.git" ]] && \
      git -C "$brew_repo" remote set-url origin "$brew_git" 2>/dev/null
    core_repo="$(brew --repo homebrew/core 2>/dev/null)"
    [[ -n "$core_repo" && -d "$core_repo/.git" ]] && \
      git -C "$core_repo" remote set-url origin "$core_git" 2>/dev/null
  fi

  echo "brew-mirror: switched to $mirror"
  echo "  Run 'brew update' to re-sync indexes."
}

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
  emulate -L zsh
  local force_settings=0 force_orphans=0
  while (( $# > 0 )); do
    case "$1" in
      -f) force_settings=1 ;;
      -y) force_orphans=1 ;;
      -h|--help)
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

  local target=".claude/settings.json"
  mkdir -p .claude/plans

  if [[ ! -e "$target" ]]; then
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

    local ans=y
    if (( ! force_settings )); then
      read -q "ans?$target exists. Merge plansDirectory into it? [y/N] " || { echo; ans=n; }
      echo
    fi

    if [[ "$ans" == [yY] ]]; then
      local tmp
      tmp="$(mktemp)" || return 1
      if jq --arg p "./.claude/plans" '. + {plansDirectory: $p}' "$target" >"$tmp"; then
        mv "$tmp" "$target"
        echo "Merged plansDirectory into $PWD/$target"
      else
        rm -f "$tmp"
        echo "claude-plans-here: jq failed; $target unchanged" >&2
        return 1
      fi
    fi
  fi

  _claude_plans_here_import_orphans "$force_orphans"
}

# Internal: scan ~/.claude/projects/<encoded-cwd|encoded-git-root>/*.jsonl
# for Write/Edit tool_use entries that wrote into ~/.claude/plans/, list the
# ones still living in the global dir and not yet copied locally, prompt y/N.
_claude_plans_here_import_orphans() {
  emulate -L zsh
  setopt local_options null_glob
  local force="$1"
  local global_plans="$HOME/.claude/plans"
  [[ -d "$global_plans" ]] || return 0

  # Claude Code projects/ encoding: replace each '/' and '.' with '-'.
  local enc_cwd="${PWD//\//-}"
  enc_cwd="${enc_cwd//./-}"
  local groot="" enc_root=""
  if command -v git >/dev/null 2>&1 && groot="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    if [[ -n "$groot" && "$groot" != "$PWD" ]]; then
      enc_root="${groot//\//-}"
      enc_root="${enc_root//./-}"
    fi
  fi

  local -a proj_dirs
  [[ -d "$HOME/.claude/projects/$enc_cwd" ]] && proj_dirs+=("$HOME/.claude/projects/$enc_cwd")
  [[ -n "$enc_root" && -d "$HOME/.claude/projects/$enc_root" ]] && proj_dirs+=("$HOME/.claude/projects/$enc_root")
  (( ${#proj_dirs} == 0 )) && return 0

  local -a jsonl_files
  local d
  for d in "${proj_dirs[@]}"; do
    jsonl_files+=("$d"/*.jsonl)
  done
  (( ${#jsonl_files} == 0 )) && return 0

  # Two-stage filter: only lines containing a Write/Edit tool_use, then
  # extract any plan-path within them. Authoritative — avoids matching plan
  # paths that merely appeared in user/assistant text.
  local re_prefix="${global_plans//./\\.}"
  local -a matches
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && matches+=("$line")
  done < <(
    grep -hE '"name":"(Write|Edit)"' "${jsonl_files[@]}" 2>/dev/null \
      | grep -oE "${re_prefix}/[A-Za-z0-9_.+-]+\.md" \
      | sort -u
  )
  (( ${#matches} == 0 )) && return 0

  local -a candidates
  local m base
  for m in "${matches[@]}"; do
    [[ -f "$m" ]] || continue
    base="${m:t}"
    [[ -e ".claude/plans/$base" ]] && continue
    candidates+=("$m")
  done
  (( ${#candidates} == 0 )) && return 0

  echo
  echo "Found ${#candidates} orphan plan(s) in ~/.claude/plans/ linked to this project:"
  for m in "${candidates[@]}"; do
    echo "  - ${m/#$HOME/~}"
  done

  local ans=y
  if (( ! force )); then
    read -q "ans?Copy them into ./.claude/plans/ (originals kept)? [y/N] " || { echo; ans=n; }
    echo
  fi
  [[ "$ans" == [yY] ]] || return 0

  local copied=0
  for m in "${candidates[@]}"; do
    cp -n "$m" .claude/plans/ && copied=$((copied + 1))
  done
  echo "Copied $copied plan(s) into $PWD/.claude/plans/"
}
