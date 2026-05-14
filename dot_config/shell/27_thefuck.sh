# 27_thefuck.sh - auto-correct previous command (cached; shared by zsh/bash).
# Run `thefuck-update-completion` to force-refresh after upgrade.
# https://github.com/nvbn/thefuck

command -v thefuck >/dev/null 2>&1 || return 0

if [ -n "$ZSH_VERSION" ]; then
    _tf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/thefuck_alias.zsh"
elif [ -n "$BASH_VERSION" ]; then
    _tf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/bash/thefuck_alias.bash"
else
    return 0
fi

_tf_bin="$(command -v thefuck)"
if [ ! -f "$_tf_cache" ] || [ "$_tf_bin" -nt "$_tf_cache" ]; then
    mkdir -p "$(dirname "$_tf_cache")"
    thefuck --alias > "$_tf_cache" 2>/dev/null
fi
[ -s "$_tf_cache" ] && . "$_tf_cache"
unset _tf_cache _tf_bin

# Optional: Use a different alias (uncomment to enable)
# eval "$(thefuck --alias fk)"
