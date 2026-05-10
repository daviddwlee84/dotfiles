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

# Disable zoxide's "init must be last" doctor warning. Our load order
# DELIBERATELY places hooks AFTER zoxide:
#   - zsh:  add-zsh-hook precmd _osc133_precmd  (zsh/tools/02_shell_integration.zsh)
#           — must run after starship which we also load via shared/01_starship
#   - bash: atuin init bash --disable-up-arrow  (dot_bashrc.tmpl step 8)
#           — must run after ble.sh source / before ble-attach
#           ble-attach itself                    (dot_bashrc.tmpl step 10)
# zoxide's heuristic "__zoxide_hook must be last in precmd_functions /
# PROMPT_COMMAND" is wrong for this setup but doesn't affect functionality
# (the hook only writes chpwd to the frecency DB; ordering is irrelevant).
# Without this, every coding-agent shell prints the doctor warning to stderr
# and agents start prefixing every chezmoi/build command with _ZO_DOCTOR=0.
# See pitfalls/zoxide-doctor-warning.md for the full diagnosis.
export _ZO_DOCTOR=0

# Initialize zoxide
if [ -n "$ZSH_VERSION" ]; then
    eval "$(zoxide init zsh)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(zoxide init bash)"
fi

# Replace cd with z for smarter directory navigation
alias cd="z"
