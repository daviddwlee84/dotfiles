# 01_omb_plugins.bash - oh-my-bash plugin/completion/alias selection.
# Sourced from dot_bashrc.tmpl BEFORE oh-my-bash.sh (sequenced via
# load_modular_dir's filename ordering — 01_ runs before OMB which the
# bashrc sources after the load_modular_dir call).
#
# Bash array variables consumed by oh-my-bash.sh — `plugins=()` etc must
# be regular bash arrays, not `declare -a`. OMB iterates them and sources
# matching files under $OSH/plugins/, $OSH/completions/, $OSH/aliases/.
#
# Plugin selection — INTENTIONALLY EXCLUDES OMB's own:
#   - autosuggestions  (ble.sh provides better native autosuggest)
#   - syntax-highlighting (ble.sh provides better native; both = flicker)
#   - history-substring-search (ble.sh's history-search subsumes it)
# Re-evaluate after dogfooding ble.sh + OMB v1.

# Skip entirely if OMB isn't installed (presence-gate; matches bashrc).
[ -d "$HOME/.oh-my-bash" ] || return 0

# Aliases bundle (~/.oh-my-bash/aliases/*.aliases.sh — selectable).
# `general` is the standard set (la, ll, ..., g, etc.); other useful
# ones can be appended in ~/.bashrc.adhoc.
aliases=(general)

# Plugins — equivalent of the zsh `plugins=(git ...)` line in dot_zshrc.tmpl.
# OMB's `git` plugin provides gst/ga/gco/gcam/gca/gca!/gcan! shortcuts
# matching oh-my-zsh's git plugin so user muscle memory transfers.
plugins=(
    git
    sudo
    bashmarks
)

# Completions — bash-completion v2 is sourced in 03_completion.bash, which
# covers most CLI tooling. OMB's bundled completions add a few extras.
completions=(
    git
    composer
    ssh
)
