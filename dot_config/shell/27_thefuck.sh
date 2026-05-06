# 27_thefuck.sh - auto-correct previous command (shell-agnostic).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir.
# thefuck auto-detects the running shell from $SHELL/$0, no flag needed.
# https://github.com/nvbn/thefuck

command -v thefuck >/dev/null 2>&1 || return 0

# Initialize thefuck with default alias 'fuck'
eval "$(thefuck --alias)"

# Optional: Use a different alias (uncomment to enable)
# eval "$(thefuck --alias fk)"
