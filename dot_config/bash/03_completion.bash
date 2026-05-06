# 03_completion.bash - bash-completion v2 source.
# Sourced from dot_bashrc.tmpl via load_modular_dir "$BASH_CONFIG_DIR" bash.
#
# Two cases:
#   1. Linux: /etc/bash_completion or /usr/share/bash-completion/bash_completion
#   2. macOS Homebrew: bash-completion@2 in $HOMEBREW_PREFIX/etc/profile.d/
#
# The Homebrew prefix is dynamic ($(brew --prefix) — /opt/homebrew on
# Apple Silicon, /usr/local on Intel) so hardcoding is unsafe. The
# `type brew` check short-circuits on non-mac systems.

# Skip on POSIX-strict mode (where bash-completion is unsupported).
shopt -oq posix && return 0

# 1. Linux distro completion
if [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
elif [ -r /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# 2. Homebrew bash-completion@2 (macOS, dynamic prefix)
if type brew >/dev/null 2>&1; then
    HB_PREFIX="$(brew --prefix 2>/dev/null)"
    if [ -n "$HB_PREFIX" ] && [ -r "$HB_PREFIX/etc/profile.d/bash_completion.sh" ]; then
        # shellcheck disable=SC1091
        . "$HB_PREFIX/etc/profile.d/bash_completion.sh"
    fi
    unset HB_PREFIX
fi
