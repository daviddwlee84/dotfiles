# 10_aliases.zsh - Common aliases

# --- Your existing aliases ---
alias v="nvim"

# --- Suggested aliases (uncomment to enable) ---
# Navigation
# alias ..="cd .."
# alias ...="cd ../.."
# alias ....="cd ../../.."

# List files
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

# Zsh startup profiling
alias zsh-profile='ZSH_PROF=1 zsh -i -c exit'

# Load NVM for current session (when needed for version switching)
alias load-nvm='export LOAD_NVM=1 && source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && source "${NVM_DIR:-$HOME/.nvm}/bash_completion" && echo "nvm loaded: $(nvm current)"'
