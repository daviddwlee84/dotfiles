# 20_zoxide.zsh - zoxide configuration

# Check if zoxide is installed
command -v zoxide &>/dev/null || return 0

# Initialize zoxide
eval "$(zoxide init zsh)"
