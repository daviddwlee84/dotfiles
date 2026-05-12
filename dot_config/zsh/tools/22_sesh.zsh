# 22_sesh.zsh - zsh wiring for the sesh tmux session manager.
# Backend (sesh-sessions, sesh-here/root/code/vibe + aliases) lives in
# dot_config/shell/22_sesh.sh and is sourced first by ~/.zshrc. This file
# adds the zsh-only layer: completion regen + ZLE widget + bindkey.
# https://github.com/joshmedeski/sesh

# Skip if sesh isn't installed (mirrors the shared backend guard).
command -v sesh &>/dev/null || return 0

# Auto-generate shell completion into ~/.zfunc/ (regenerates on version change).
# Bash uses a different completion path; that's handled elsewhere if needed.
if [[ -d ~/.zfunc ]]; then
    local _sesh_ver="$(sesh --version 2>/dev/null)"
    if [[ ! -f ~/.zfunc/_sesh ]] || ! grep -q "${_sesh_ver}" ~/.zfunc/_sesh 2>/dev/null; then
        sesh completion zsh > ~/.zfunc/_sesh 2>/dev/null
    fi
fi

# Register the picker as a zle widget.
# `sesh-sessions` (the function body) is defined in dot_config/shell/22_sesh.sh.
zle -N sesh-sessions

# Key bindings (Alt+S for session switcher, avoids conflict with Ctrl+A tmux prefix)
bindkey -M emacs '\es' sesh-sessions
bindkey -M viins '\es' sesh-sessions
bindkey -M vicmd '\es' sesh-sessions
