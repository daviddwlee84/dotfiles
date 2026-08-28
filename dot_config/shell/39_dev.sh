# shellcheck shell=sh
# 39_dev.sh - dev-cli shell integration (shared bash + zsh).
# https://github.com/daviddwlee84/dev-cli
#
# `dev resume`, `dev start`, and worktree/repository open commands can hand a
# directory change back to the parent shell. Source the generated wrapper at
# startup rather than asking the CLI to edit managed rc files.

# Skip silently on profiles where the CLI is not installed.
command -v dev >/dev/null 2>&1 || return 0

if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(command dev shell-init zsh 2>/dev/null)"
elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(command dev shell-init bash 2>/dev/null)"
fi
