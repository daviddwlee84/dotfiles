# 90_completions.zsh - Autocompletion setup
# Loaded last to ensure all fpath additions are captured

# Add custom completion directories
fpath+=~/.zfunc

# Docker completions (if available)
[[ -d ~/.docker/completions ]] && fpath=(~/.docker/completions $fpath)

# Initialize completion system
autoload -Uz compinit && compinit
