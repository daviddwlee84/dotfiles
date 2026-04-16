# 12_television.zsh - Television (tv) shell integration
#
# Tab completion only (via `tv completions zsh`).
# We do NOT use `tv init zsh` because it binds Ctrl+T and Ctrl+R,
# which conflict with fzf's shell integration.
#
# Instead, tv channels are bound to Alt keys:
#   Alt+R  tv shell history     (tv-style history search)
#   Alt+F  tv files             (tv-style file picker)
#   Alt+G  tv git-log           (git log browser)
#   Alt+E  tv env               (environment variables)
#   Alt+A  tv aliases           (all aliases & functions)
#
# fzf keeps Ctrl+T / Ctrl+R / Alt+C (muscle memory).
# tv gets Alt namespace for advanced pickers.
#
# See: https://github.com/alexpasmantier/television

command -v tv &>/dev/null || return 0

# --- Tab completion only (no keybindings) ---
eval "$(tv completions zsh)"

# --- Custom ZLE widgets for tv channels ---

_tv_channel_widget() {
  emulate -L zsh
  zle -I
  local output
  output=$(tv "$1" --no-status-bar --inline < /dev/tty)
  zle reset-prompt
  if [[ -n $output ]]; then
    LBUFFER+="$output"
  fi
}

_tv_history() {
  emulate -L zsh
  zle -I
  local output current_prompt
  current_prompt=$LBUFFER
  output=$(history -n -1 0 | tv --no-status-bar --input "$current_prompt" --inline < /dev/tty)
  zle reset-prompt
  if [[ -n $output ]]; then
    RBUFFER=""
    LBUFFER="$output"
  fi
}

_tv_files()   { _tv_channel_widget "files"; }
_tv_gitlog()  { _tv_channel_widget "git-log"; }
_tv_env()     { _tv_channel_widget "env"; }
_tv_aliases() { _tv_channel_widget "aliases"; }

zle -N tv-history  _tv_history
zle -N tv-files    _tv_files
zle -N tv-gitlog   _tv_gitlog
zle -N tv-env      _tv_env
zle -N tv-aliases  _tv_aliases

# --- Keybindings (Alt namespace) ---
bindkey '\er' tv-history   # Alt+R
bindkey '\ef' tv-files     # Alt+F
bindkey '\eg' tv-gitlog    # Alt+G
bindkey '\ee' tv-env       # Alt+E
bindkey '\ea' tv-aliases   # Alt+A
