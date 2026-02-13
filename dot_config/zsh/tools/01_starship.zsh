# Starship prompt - https://starship.rs/
# Init must run after oh-my-zsh is loaded (which sets ZSH_THEME="")
if command -v starship &> /dev/null; then
    eval "$(starship init zsh)"
fi
