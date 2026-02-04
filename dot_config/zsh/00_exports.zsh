# 00_exports.zsh - Environment variables

# Editor
if [[ -n $SSH_CONNECTION ]]; then
    export EDITOR='vim'
else
    export EDITOR='nvim'
fi
export VISUAL="$EDITOR"

# Language
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# PATH additions
export PATH="$HOME/.local/bin:$PATH"

# --- Suggested exports (uncomment to enable) ---
# History configuration (oh-my-zsh handles this, but can customize)
# export HISTSIZE=10000
# export SAVEHIST=10000
# export HISTFILE="$XDG_DATA_HOME/zsh/history"
