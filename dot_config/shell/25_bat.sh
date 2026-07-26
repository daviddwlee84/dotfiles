# 25_bat.sh - bat configuration (shared by zsh/bash)

# Check if bat is installed
command -v bat &>/dev/null || return 0

# Tokyo Night theme. The `.tmTheme` source is managed by chezmoi at
# ~/.config/bat/themes/, and compiled into bat's binary cache by
# .chezmoiscripts/global/run_after_25_bat_theme.sh.tmpl.
#
# BAT_THEME is exported ONLY when that compiled cache is actually present. bat
# prints
#   [bat warning]: Unknown theme 'tokyonight_night', using default.
# on EVERY invocation when the theme isn't compiled in — which means every fzf /
# tv / yazi preview and every `delta` render, one warning line each. The cache
# is legitimately absent in two cases: on a fresh box before the first
# `chezmoi apply`, and on hosts where the run-script deliberately cleared it
# because the installed bat/delta pair is incompatible (see
# pitfalls/git-delta-empty-stdin-huge-allocation.md). Leaving BAT_THEME unset
# there makes bat fall back to its own default silently instead of warning.
#
# See pitfalls/bat-theme-cache-cleared-never-rebuilt.md.
_bat_cache_dir="${BAT_CACHE_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/bat}"
_bat_theme_file="${BAT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/bat}/themes/tokyonight_night.tmTheme"
if [ -f "$_bat_cache_dir/themes.bin" ] && [ -f "$_bat_theme_file" ]; then
    export BAT_THEME="tokyonight_night"
fi
unset _bat_cache_dir _bat_theme_file
