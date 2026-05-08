# 34_openclaw.sh - OpenClaw completion (shared by zsh/bash)

# Check if openclaw is installed
command -v openclaw >/dev/null 2>&1 || return 0

# Source OpenClaw completions for the *current* shell. The CLI ships
# per-shell completer files under ~/.openclaw/completions/.
if [ -n "$ZSH_VERSION" ]; then
    [ -f "$HOME/.openclaw/completions/openclaw.zsh" ] && \
        . "$HOME/.openclaw/completions/openclaw.zsh"
elif [ -n "$BASH_VERSION" ]; then
    [ -f "$HOME/.openclaw/completions/openclaw.bash" ] && \
        . "$HOME/.openclaw/completions/openclaw.bash"
fi
