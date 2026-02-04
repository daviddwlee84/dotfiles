# 05_mise.zsh - mise runtime manager
# https://mise.jdx.dev/

# Find mise binary (user install or system install)
if [[ -x "$HOME/.local/bin/mise" ]]; then
    _mise_bin="$HOME/.local/bin/mise"
elif command -v mise &>/dev/null; then
    _mise_bin="mise"
else
    return 0
fi

# Activate mise (adds shims to PATH and enables tool switching)
eval "$($_mise_bin activate zsh)"
unset _mise_bin
