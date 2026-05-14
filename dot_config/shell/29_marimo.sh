# 29_marimo.sh - marimo shell completion (cached; shared by zsh/bash).
# Run `marimo-update-completion` to force-refresh after upgrade edge cases
# (e.g. `uv tool upgrade marimo` where the binary mtime check below misses).

command -v marimo >/dev/null 2>&1 || return 0

if [ -n "$ZSH_VERSION" ]; then
    _marimo_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/marimo_completion.zsh"
    _marimo_shell=zsh
elif [ -n "$BASH_VERSION" ]; then
    _marimo_cache="${XDG_CACHE_HOME:-$HOME/.cache}/bash/marimo_completion.bash"
    _marimo_shell=bash
else
    return 0
fi

_marimo_bin="$(command -v marimo)"
if [ ! -f "$_marimo_cache" ] || [ "$_marimo_bin" -nt "$_marimo_cache" ]; then
    mkdir -p "$(dirname "$_marimo_cache")"
    _MARIMO_COMPLETE="${_marimo_shell}_source" marimo > "$_marimo_cache" 2>/dev/null
fi
[ -s "$_marimo_cache" ] && . "$_marimo_cache"
unset _marimo_cache _marimo_shell _marimo_bin
