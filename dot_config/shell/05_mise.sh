# 05_mise.sh - mise runtime manager (shell-detecting).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir.
# https://mise.jdx.dev/

# Find mise binary (user install or system install)
if [ -x "$HOME/.local/bin/mise" ]; then
    _mise_bin="$HOME/.local/bin/mise"
elif command -v mise >/dev/null 2>&1; then
    _mise_bin="mise"
else
    return 0
fi

# Activate mise (adds shims to PATH and enables tool switching)
if [ -n "$ZSH_VERSION" ]; then
    eval "$($_mise_bin activate zsh)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$($_mise_bin activate bash)"
fi
unset _mise_bin
