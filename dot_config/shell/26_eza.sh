# 26_eza.sh - eza configuration (modern ls replacement; shared by zsh/bash)

# Check if eza is installed
command -v eza &>/dev/null || return 0

# Replace ls with eza
# Options:
#   --icons=always  - Show file type icons
#   --color=always  - Enable colors
#   --group-directories-first - Keep directories grouped together
# Uses eza's default compact grid layout (multiple items per line)
alias ls="eza --icons=always --color=always --group-directories-first"

# Additional useful aliases
alias la="eza --icons=always --color=always --long --header --git --git-repos --group-directories-first --time-style=long-iso --all"
alias ll="eza --icons=always --color=always --long --header --git --git-repos --group-directories-first --time-style=long-iso"
alias lt="eza --icons=always --color=always --tree --level=2"
alias llt="eza --icons=always --color=always --long --header --git --git-repos --group-directories-first --time-style=long-iso --tree --level=3"
