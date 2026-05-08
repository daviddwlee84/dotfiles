# 25_bat.sh - bat configuration (shared by zsh/bash)

# Check if bat is installed
command -v bat &>/dev/null || return 0

# The Tokyo Night theme file is managed by chezmoi at ~/.config/bat/themes/
# and the cache is rebuilt by run_onchange_after_25_bat_theme.sh.tmpl.
export BAT_THEME="tokyonight_night"
