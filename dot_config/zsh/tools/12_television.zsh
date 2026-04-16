# 12_television.zsh - Television (tv) shell integration
#
# Tab completion via ~/.zfunc/_tv (regenerated on version change).
# We do NOT use `tv init zsh` because it binds Ctrl+T and Ctrl+R,
# which conflict with fzf's shell integration.
#
# Instead, tv channels are bound to Alt keys:
#   Alt+R  tv shell history     (tv-style history search)
#   Alt+P  tv files             (tv-style file/path picker)
#   Alt+G  tv git-log           (git log browser)
#   Alt+E  tv env               (environment variables)
#   Alt+A  tv aliases           (all aliases & functions)
#
# fzf keeps Ctrl+T / Ctrl+R / Alt+C (muscle memory).
# tv gets Alt namespace for advanced pickers.
#
# Aliases cache: ~/.cache/tv/aliases.txt is generated on shell startup
# so that `tv aliases` channel can read it without spawning `zsh -ic`
# (which causes tty suspend issues).
#
# See: https://github.com/alexpasmantier/television

command -v tv &>/dev/null || return 0

# --- Tab completion (written to ~/.zfunc/, picked up by compinit) ---
if [[ -d ~/.zfunc ]]; then
  local _tv_ver="$(tv --version 2>/dev/null)"
  if [[ ! -f ~/.zfunc/_tv ]] || ! grep -q "${_tv_ver}" ~/.zfunc/_tv 2>/dev/null; then
    tv completions zsh > ~/.zfunc/_tv 2>/dev/null
  fi
fi

# --- Generate aliases cache for tv aliases channel ---
{
  mkdir -p ~/.cache/tv
  {
    alias | while IFS="=" read -r name rest; do
      printf "%-22s  alias   %s\n" "$name" "$rest"
    done
    typeset -f + | while read -r name; do
      printf "%-22s  func\n" "$name"
    done
  } | sort > ~/.cache/tv/aliases.txt
} &>/dev/null &!

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
# Note: Alt+F is reserved for forward-word (emacs mode default).
bindkey '\er' tv-history   # Alt+R
bindkey '\ep' tv-files     # Alt+P (path/pick)
bindkey '\eg' tv-gitlog    # Alt+G
bindkey '\ee' tv-env       # Alt+E
bindkey '\ea' tv-aliases   # Alt+A
