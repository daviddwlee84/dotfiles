# 95_bitwarden.zsh - Bitwarden CLI completion and SSH agent integration

# TODO:: Consider if we want to automatically set SSH_AUTH_SOCK for Bitwarden SSH agent, or set in ~/.ssh/config manually?

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

# Prefer Bitwarden SSH Agent when its socket exists
typeset -a _bw_ssh_candidates

if [[ "$OSTYPE" == darwin* ]]; then
    _bw_ssh_candidates=(
        "$HOME/Library/Application Support/Bitwarden/.bitwarden-ssh-agent.sock"
        "$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"
        "$HOME/.bitwarden-ssh-agent.sock"
    )
else
    _bw_ssh_candidates=(
        "$HOME/.bitwarden-ssh-agent.sock"
        "$HOME/snap/bitwarden/current/.bitwarden-ssh-agent.sock"
        "$HOME/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock"
    )
fi

for _bw_sock in "${_bw_ssh_candidates[@]}"; do
    if [[ -S "$_bw_sock" ]]; then
        export SSH_AUTH_SOCK="$_bw_sock"
        break
    fi
done

unset _bw_sock _bw_ssh_candidates
