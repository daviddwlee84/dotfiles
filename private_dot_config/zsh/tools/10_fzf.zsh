# 10_fzf.zsh - fzf configuration

# Check if fzf is installed
command -v fzf &>/dev/null || return 0

# Load fzf shell integration
source <(fzf --zsh)

# --- Suggested fzf options (uncomment to enable) ---
# export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border"

# Use fd for fzf if available (faster than find)
# if command -v fd &>/dev/null; then
#     export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"
#     export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
#     export FZF_ALT_C_COMMAND="fd --type d --hidden --follow --exclude .git"
# fi
