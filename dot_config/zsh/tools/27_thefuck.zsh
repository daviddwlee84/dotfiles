# 27_thefuck.zsh - thefuck configuration (auto-correct commands)

# Check if thefuck is installed
command -v thefuck &>/dev/null || return 0

# Initialize thefuck with default alias 'fuck'
eval $(thefuck --alias)

# Optional: Use a different alias (uncomment to enable)
# eval $(thefuck --alias fk)
