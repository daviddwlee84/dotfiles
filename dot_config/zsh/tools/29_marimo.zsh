# 29_marimo.zsh - marimo shell completion

# Check if marimo is installed
command -v marimo &>/dev/null || return 0

# Enable marimo zsh completion
eval "$(_MARIMO_COMPLETE=zsh_source marimo)"
