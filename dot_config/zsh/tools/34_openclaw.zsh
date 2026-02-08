# 34_openclaw.zsh - OpenClaw completion

# Check if openclaw is installed
command -v openclaw &>/dev/null || return 0

# Source OpenClaw completions
[[ -f ~/.openclaw/completions/openclaw.zsh ]] && source ~/.openclaw/completions/openclaw.zsh
