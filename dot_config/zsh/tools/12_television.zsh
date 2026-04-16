# 12_television.zsh - Television (tv) shell integration
#
# Provides:
# - Shell completion for tv subcommands and channel names (tab completion)
# - Smart autocomplete integration (Ctrl+T for files, Ctrl+R for history, etc.)
#
# See: https://github.com/alexpasmantier/television

if command -v tv &>/dev/null; then
  eval "$(tv init zsh)"
fi
