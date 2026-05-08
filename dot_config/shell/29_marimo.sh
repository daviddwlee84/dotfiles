# 29_marimo.sh - marimo shell completion (shared by zsh/bash)

# Check if marimo is installed
command -v marimo >/dev/null 2>&1 || return 0

# marimo uses click — feed it the right `_MARIMO_COMPLETE=<shell>_source` env
# var per shell. The output is a self-contained completion script eval'd
# into the current shell.
if [ -n "$ZSH_VERSION" ]; then
    eval "$(_MARIMO_COMPLETE=zsh_source marimo 2>/dev/null)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(_MARIMO_COMPLETE=bash_source marimo 2>/dev/null)"
fi
