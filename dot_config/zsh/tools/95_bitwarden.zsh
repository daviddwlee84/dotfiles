# 95_bitwarden.zsh - Bitwarden CLI zsh completion
#
# SSH agent integration has moved to 94_ssh_agent.zsh which provides
# Bitwarden-first detection with automatic fallback to ssh-agent.

# Check if Bitwarden CLI is installed
command -v bw &>/dev/null || return 0

# Enable Bitwarden zsh completion (cached — bw is a slow Node.js app)
# Run `bw-update-completion` to regenerate after updating bw
_bw_comp_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/bw_completion.zsh"
if [[ ! -f "$_bw_comp_cache" ]]; then
    mkdir -p "${_bw_comp_cache:h}"
    bw completion --shell zsh 2>/dev/null > "$_bw_comp_cache"
fi
[[ -s "$_bw_comp_cache" ]] && source "$_bw_comp_cache"
unset _bw_comp_cache
