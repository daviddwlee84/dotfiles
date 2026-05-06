# 20_zoxide.sh - smart cd replacement (shell-detecting).
# Sourced by both ~/.zshrc and ~/.bashrc via load_modular_dir.
# https://github.com/ajeetdsouza/zoxide

command -v zoxide >/dev/null 2>&1 || return 0

# Resolve symlinks before recording, so that paths like
#   ~/Documents/Program -> /Volumes/Data/Program
#   ~/src/tries         -> /Volumes/Data/Program/tries
# don't fragment frecency scores into two phantom entries (one per surface
# path). With this on, every cd records the canonical /Volumes/... path and
# the same physical directory always accumulates score, regardless of which
# symlink you entered through. `z <query>` still jumps correctly because the
# resolved target is what gets stored.
export _ZO_RESOLVE_SYMLINKS=1

# Initialize zoxide
if [ -n "$ZSH_VERSION" ]; then
    eval "$(zoxide init zsh)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(zoxide init bash)"
fi

# Replace cd with z for smarter directory navigation
alias cd="z"
