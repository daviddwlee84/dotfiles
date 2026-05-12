# 35_yazi.sh - yazi file manager configuration (shared bash + zsh).
# Moved from dot_config/zsh/tools/35_yazi.zsh; file already used only
# POSIX-portable constructs (mktemp, IFS= read -r -d '', builtin cd).

# Check if yazi is installed
command -v yazi &>/dev/null || return 0

# Wrapper function to change directory on exit
# When you quit yazi, it will cd to the directory you were browsing
function y() {
    local tmp cwd
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    command yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd < "$tmp"
    [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
    rm -f -- "$tmp"
}
