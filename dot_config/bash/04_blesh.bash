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

# === Multi-line submit: Ctrl+Enter ===
#
# Default ble.sh + vi-mode behaviour: when the buffer contains a newline
# (multi-line paste, multi-line typed input, here-doc etc.), the shell
# enters MULTILINE mode and plain RET / Ctrl-M re-binds to "insert
# newline" rather than "submit" — meaning Enter alone won't run the
# command. The official escape is Ctrl-J (linefeed = accept-line), but
# tmux's vim-tmux-navigator already eats `C-j` for pane navigation
# (dot_config/tmux/keybindings.conf:183), so it never reaches ble.sh.
#
# Ctrl+Enter is the cleanest free key on this stack:
#   - tmux extended-keys + xterm:extkeys are enabled, so Ctrl+Enter
#     sends a distinct CSI-u sequence (\e[13;5u) which tmux forwards
#     intact (no collision with C-j).
#   - ble.sh sees `C-RET` as a separate keysym when extended-keys flow
#     through, and binds it independently from `RET` / `C-m`.
#   - Plain RET still does the safe-multiline-newline thing — useful for
#     intentionally building multi-line commands.
#
# If your terminal can't emit Ctrl+Enter as CSI-u (some minimal SSH
# clients), Alt+Enter (`M-RET` below) is a portable fallback.
ble-bind -m vi_imap -f 'C-RET' accept-line
ble-bind -m vi_nmap -f 'C-RET' accept-line
ble-bind -m vi_imap -f 'M-RET' accept-line
ble-bind -m vi_nmap -f 'M-RET' accept-line
