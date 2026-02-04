# 26_eza.zsh - eza configuration (modern ls replacement)

# Check if eza is installed
command -v eza &>/dev/null || return 0

# Replace ls with eza
# Options:
#   --icons=always  - Show file type icons
#   --color=always  - Enable colors
#   --long          - Long format
#   --git           - Show git status
#   --no-filesize   - Hide file size
#   --no-time       - Hide modification time
#   --no-user       - Hide user/owner
#   --no-permissions - Hide permissions
alias ls="eza --icons=always --color=always --long --git --no-filesize --no-time --no-user --no-permissions"

# Additional useful aliases
alias la="eza --icons=always --color=always --long --git --all"
alias ll="eza --icons=always --color=always --long --git"
alias lt="eza --icons=always --color=always --tree --level=2"
