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
