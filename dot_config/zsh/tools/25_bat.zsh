# 25_bat.zsh - bat configuration

# Check if bat is installed
command -v bat &>/dev/null || return 0

# Set bat theme (tokyo-night requires manual theme installation)
# To install: mkdir -p "$(bat --config-dir)/themes" && cd "$(bat --config-dir)/themes" && \
#   curl -O https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/sublime/tokyonight_night.tmTheme && \
#   bat cache --build
export BAT_THEME="tokyonight_night"

# Fallback to a built-in theme if tokyonight is not installed
# Uncomment the line below if you prefer a built-in theme:
# export BAT_THEME="Dracula"
