# 95_bitwarden.zsh - Bitwarden CLI completion and SSH agent integration

# Check if Bitwarden CLI is installed
command -v bw &>/dev/null || return 0

# Enable Bitwarden zsh completion
eval "$(bw completion --shell zsh 2>/dev/null)"

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
