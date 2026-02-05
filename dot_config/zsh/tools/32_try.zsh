# 32_try.zsh - try-cli configuration (interactive gem tryouts)
# https://github.com/joshmfrankel/try

command -v try &>/dev/null || return 0

eval "$(try init)"
