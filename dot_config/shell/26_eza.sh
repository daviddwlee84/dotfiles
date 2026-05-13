# 26_eza.sh - eza configuration (modern ls replacement; shared by zsh/bash)

# Check if eza is installed
command -v eza &>/dev/null || return 0

# Replace ls with eza
# Options:
#   --icons=auto   - Show icons on TTY; disabled when piped (so `ls | grep` is clean)
#   --color=auto   - Colors on TTY; disabled when piped
#   --group-directories-first - Keep directories grouped together
# Interactive use looks identical; pipes get plain output automatically.
# To force colors through a pager: `ls --color=always --icons=always | less -R`.
alias ls="eza --icons=auto --color=auto --group-directories-first"

# Additional useful aliases
alias la="eza --icons=auto --color=auto --long --header --git --git-repos --group-directories-first --time-style=long-iso --all"
alias ll="eza --icons=auto --color=auto --long --header --git --git-repos --group-directories-first --time-style=long-iso"
alias lt="eza --icons=auto --color=auto --tree --level=2"
alias llt="eza --icons=auto --color=auto --long --header --git --git-repos --group-directories-first --time-style=long-iso --tree --level=3"
