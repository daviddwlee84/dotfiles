# 40_codexbar.sh - CodexBar CLI aliases (AI usage tracker; shared by zsh/bash)

# Check if codexbar is installed
command -v codexbar &>/dev/null || return 0

# Usage aliases (--source cli required on Linux)
alias cbu="codexbar usage --provider claude --source cli"
alias cbc="codexbar cost --provider claude"
alias cbca="codexbar cost"
