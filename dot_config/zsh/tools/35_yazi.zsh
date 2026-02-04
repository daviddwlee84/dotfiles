# 35_yazi.zsh - yazi file manager configuration

# Check if yazi is installed
command -v yazi &>/dev/null || return 0

# Wrapper function to change directory on exit
# When you quit yazi, it will cd to the directory you were browsing
function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
    command yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd < "$tmp"
    [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
    rm -f -- "$tmp"
}
