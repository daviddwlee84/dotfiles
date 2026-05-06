# 05_vi_mode.bash - vi-style command-line editing.
# Sourced from dot_bashrc.tmpl via load_modular_dir "$BASH_CONFIG_DIR" bash.
#
# `set -o vi` enables readline vi mode — modal editing with ESC entering
# normal mode and `i` returning to insert. Less feature-rich than
# zsh-vi-mode (no surround / text-objects beyond readline's basics) but
# adequate for most workflows. ble.sh, when loaded, layers a much more
# zsh-vi-mode-like experience on top — its vi-mode auto-activates if
# ble.sh detects `set -o vi` is set, so this line is the trigger for
# both plain bash and ble.sh paths.

set -o vi
