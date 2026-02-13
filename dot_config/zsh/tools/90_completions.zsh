# 90_completions.zsh - Autocompletion setup
# Loaded last to ensure all fpath additions are captured

# Add custom completion directories
fpath+=~/.zfunc

# zsh-completions (additional completions for 300+ commands)
[[ -d ~/.oh-my-zsh/custom/plugins/zsh-completions/src ]] && fpath=(~/.oh-my-zsh/custom/plugins/zsh-completions/src $fpath)

# Docker completions (if available)
[[ -d ~/.docker/completions ]] && fpath=(~/.docker/completions $fpath)

# Initialize completion system
# Regenerate .zcompdump only if older than 24 hours; otherwise skip security check (-C)
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi
