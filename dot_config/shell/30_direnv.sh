# 30_direnv.sh - direnv hook (shell-detecting).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir.
# https://direnv.net/

command -v direnv >/dev/null 2>&1 || return 0

if [ -n "$ZSH_VERSION" ]; then
    eval "$(direnv hook zsh)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(direnv hook bash)"
fi
