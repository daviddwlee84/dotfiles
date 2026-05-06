# 10_aliases.zsh - Zsh-only aliases / functions.
#
# POSIX-portable aliases (v=nvim, chezmoi-cd, gcam-amend, gundo, glop,
# load-nvm, bw-update-completion, ghostty-ssh-terminfo, brew-mirror,
# claude-plans-here) live in dot_config/shell/10_aliases.sh and are
# sourced by both ~/.zshrc and ~/.bashrc.
#
# Only zsh-specific helpers stay here. OMZ git-plugin shortcuts (gca,
# gcam, gca!, gcan!) are provided by the `git` plugin loaded in
# dot_zshrc.tmpl.

# Zsh startup profiling — `ZSH_PROF=1 zsh` triggers zprof at the end
# of dot_zshrc.tmpl; the alias just makes the one-shot profile run
# convenient.
alias zsh-profile='ZSH_PROF=1 zsh -i -c exit'
