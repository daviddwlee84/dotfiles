# 01_starship.sh - Starship prompt initialization (shell-detecting).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir.
# Init must run after oh-my-zsh / oh-my-bash is loaded (which sets THEME="").
# https://starship.rs/

command -v starship >/dev/null 2>&1 || return 0

if [ -n "$ZSH_VERSION" ]; then
    eval "$(starship init zsh)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(starship init bash)"
fi
