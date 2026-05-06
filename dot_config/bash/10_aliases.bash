# 10_aliases.bash - bash-only aliases that don't fit the shared layer.
# Sourced from dot_bashrc.tmpl via load_modular_dir "$BASH_CONFIG_DIR" bash.
#
# POSIX-portable aliases live in dot_config/shell/10_aliases.sh and are
# already loaded by the time this file runs.

# bash startup profiling — `BASH_PROF=1 bash -i` triggers it at exit.
# Sister to zsh's `zsh-profile` alias.
alias bash-profile='BASH_PROF=1 bash -ic exit'

# Re-source bashrc in current shell (handy after editing config).
alias reload='. ~/.bashrc'
