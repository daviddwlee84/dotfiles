# 30_direnv.zsh - direnv configuration

# Check if direnv is installed
command -v direnv &>/dev/null || return 0

# Initialize direnv
eval "$(direnv hook zsh)"
