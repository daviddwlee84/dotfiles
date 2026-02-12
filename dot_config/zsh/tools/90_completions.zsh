# 90_completions.zsh - Autocompletion setup
# Loaded last to ensure all fpath additions are captured

# Add custom completion directories
fpath+=~/.zfunc

# zsh-completions (additional completions for 300+ commands)
[[ -d ~/.oh-my-zsh/custom/plugins/zsh-completions/src ]] && fpath=(~/.oh-my-zsh/custom/plugins/zsh-completions/src $fpath)

# Docker completions (if available)
[[ -d ~/.docker/completions ]] && fpath=(~/.docker/completions $fpath)

# Initialize completion system
autoload -Uz compinit && compinit
