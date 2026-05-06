# 04_blesh.bash - ble.sh-specific tweaks.
# Sourced from dot_bashrc.tmpl AFTER ble.sh's --attach=none source but
# BEFORE ble-attach (the `bleopt` settings here are read at attach time).
# Skipped when ble.sh isn't loaded (no $BLE_VERSION) so plain bash users
# don't see errors.

[[ -z $BLE_VERSION ]] && return 0

# complete_auto_complete = autosuggest mode. 1 = enabled (fish-style ghost
# text); empty = disabled. Default to enabled — the whole point of
# bringing in ble.sh is the zsh-autosuggestions parity.
bleopt complete_auto_complete=1

# Hide the message ble.sh prints on attach (attach-greeting), keeps shell
# startup quiet.
bleopt prompt_eol_mark=

# Vi-mode keymap: ble.sh auto-detects `set -o vi` (set in 05_vi_mode.bash)
# and activates its full vi-mode. No additional config needed.

# Custom keybindings — currently none. Drop ble-bind invocations here
# (e.g., `ble-bind -x 'C-r' 'atuin-search-bash'`) when porting zsh
# widgets to bash; reminder: anything that was `bindkey -M viins` in zsh
# is `ble-bind -m vi_imap -x` in ble.sh.
