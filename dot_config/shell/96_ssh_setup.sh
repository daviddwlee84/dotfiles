# 96_ssh_setup.sh - Interactive SSH key setup for remote machines (shared).
# Moved from dot_config/zsh/tools/96_ssh_setup.zsh. Zsh-isms replaced:
#   emulate -L zsh                  → gated on $ZSH_VERSION
#   setopt localoptions pipefail    → gated on $ZSH_VERSION (bash: set -o pipefail)
#   ~/.ssh/*.pub(N)  (nullglob)     → shopt -s nullglob / setopt nullglob dispatch
#   print -u2 --                    → printf >&2
#   print "..."                     → printf
#   print -n "..."                  → printf '%s' (no newline)
#   ${key_path:t}    (basename)     → ${key_path##*/}
#   ${#existing_keys}               → ${#existing_keys[@]}
#
# Usage: ssh-setup-remote [user@]host
#
# Walks through: create key → ssh-copy-id → copy key to remote → add SSH config entries.
# See docs/tutorials/setup_ssh_key_on_remote.md for the full tutorial.

ssh-setup-remote() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  local usage="Usage: ssh-setup-remote [user@]host"
  if [ $# -ne 1 ]; then
    printf '%s\n' "$usage" >&2
    return 1
  fi

  local target="$1"
  local remote_user remote_host
  if [[ "$target" == *@* ]]; then
    remote_user="${target%%@*}"
    remote_host="${target#*@}"
  else
    remote_host="$target"
    remote_user=""
  fi

  # ── Step 0: Key selection ──────────────────────────────────────────────
  printf '\n%s\n' "=== SSH Key Setup for $target ==="

  local key_path=""
  local create_new=""

  printf '\nExisting keys in ~/.ssh/:\n'

  # Portable nullglob: in zsh, `*.pub(N)` made the glob expand to nothing
  # when nothing matched. shopt -s nullglob (bash) / setopt nullglob (zsh)
  # is the equivalent.
  local -a existing_keys
  existing_keys=()
  if [ -n "$ZSH_VERSION" ]; then
    setopt localoptions nullglob
  else
    local _had_nullglob; _had_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
    shopt -s nullglob
  fi

  local f
  for f in ~/.ssh/*.pub; do
    existing_keys+=("${f%.pub}")
    printf '  %s\n' "${f%.pub}"
  done

  # Restore bash nullglob; zsh is already locally scoped via setopt localoptions.
  if [ -n "$BASH_VERSION" ]; then
    eval "$_had_nullglob"
  fi

  if (( ${#existing_keys[@]} > 0 )); then
    printf '\nUse an existing key? [Y/n] '
    read -r create_new
    if [[ "$create_new" =~ ^[Nn] ]]; then
      create_new="yes"
    else
      printf 'Enter key path (without .pub): '
      read -r key_path
      # Expand ~ manually
      key_path="${key_path/#\~/$HOME}"
      if [ ! -f "$key_path" ] && [ ! -f "${key_path}.pub" ]; then
        printf '%s\n' "Key not found: $key_path" >&2
        return 1
      fi
    fi
  else
    printf '  (none found)\n'
    create_new="yes"
  fi

  # ── Step 0b: Create new key ────────────────────────────────────────────
  if [ "$create_new" = "yes" ]; then
    printf '\n--- Create new SSH key ---\n'

    # Algorithm
    local algo="ed25519"
    printf 'Algorithm [ed25519] (ed25519/ed25519-sk/rsa): '
    local algo_input
    read -r algo_input
    [ -n "$algo_input" ] && algo="$algo_input"

    # Key name
    local key_name="id_${algo}_${remote_host}"
    printf 'Key name [%s]: ' "$key_name"
    local name_input
    read -r name_input
    [ -n "$name_input" ] && key_name="$name_input"
    key_path="$HOME/.ssh/$key_name"

    if [ -f "$key_path" ]; then
      printf '%s\n' "Key already exists: $key_path" >&2
      return 1
    fi

    # Comment
    local comment="${USER}@$(hostname -s) -> ${remote_host}"
    printf 'Comment [%s]: ' "$comment"
    local comment_input
    read -r comment_input
    [ -n "$comment_input" ] && comment="$comment_input"

    # Passphrase
    local -a passphrase_flag
    passphrase_flag=()
    printf 'Set a passphrase? [y/N] '
    local use_pass
    read -r use_pass
    if [[ "$use_pass" =~ ^[Yy] ]]; then
      # Let ssh-keygen prompt for it
      passphrase_flag=()
    else
      passphrase_flag=(-N "")
    fi

    # Generate
    local -a keygen_args
    keygen_args=(-t "$algo" -f "$key_path" -C "$comment" "${passphrase_flag[@]}")
    [ "$algo" = "rsa" ] && keygen_args+=(-b 4096)

    printf '\n> ssh-keygen %s\n' "${keygen_args[*]}"
    ssh-keygen "${keygen_args[@]}" || return 1
    printf '\nKey created: %s\n' "$key_path"
  fi

  # ── Step 1: ssh-copy-id ────────────────────────────────────────────────
  printf '\n--- Copy public key to %s ---\n' "$target"
  printf 'Run ssh-copy-id to enable passwordless login? [Y/n] '
  local do_copy
  read -r do_copy
  if [[ ! "$do_copy" =~ ^[Nn] ]]; then
    printf '\n> ssh-copy-id -i %s.pub %s\n' "$key_path" "$target"
    ssh-copy-id -i "${key_path}.pub" "$target" || {
      printf '%s\n' "ssh-copy-id failed. You may need to enter the remote password." >&2
      return 1
    }
  fi

  # ── Step 2: Copy key pair to remote ────────────────────────────────────
  printf '\n--- Copy key pair to remote ---\n'
  printf 'This lets the remote machine use the same key (e.g. for GitHub).\n'
  printf 'Copy private+public key to %s:~/.ssh/? [y/N] ' "$target"
  local do_scp
  read -r do_scp
  if [[ "$do_scp" =~ ^[Yy] ]]; then
    local key_basename="${key_path##*/}"
    printf '\n> scp %s %s.pub %s:~/.ssh/\n' "$key_path" "$key_path" "$target"
    scp "$key_path" "${key_path}.pub" "$target:~/.ssh/" || return 1
    ssh "$target" "chmod 600 ~/.ssh/$key_basename && chmod 644 ~/.ssh/${key_basename}.pub"
    printf 'Key copied and permissions set.\n'

    # Configure GitHub on remote
    printf '\nAdd GitHub SSH config on remote? [y/N] '
    local do_github
    read -r do_github
    if [[ "$do_github" =~ ^[Yy] ]]; then
      ssh "$target" "mkdir -p ~/.ssh && cat >> ~/.ssh/config" <<EOF

Host github.com
    IdentityFile ~/.ssh/$key_basename
EOF
      ssh "$target" "chmod 600 ~/.ssh/config"
      printf 'GitHub SSH config added on remote.\n'
    fi
  fi

  # ── Step 3: Local SSH config ───────────────────────────────────────────
  printf '\n--- Local SSH config ---\n'
  printf 'Add host alias to local ~/.ssh/config? [Y/n] '
  local do_config
  read -r do_config
  if [[ ! "$do_config" =~ ^[Nn] ]]; then
    local host_alias="$remote_host"
    printf 'Host alias [%s]: ' "$host_alias"
    local alias_input
    read -r alias_input
    [ -n "$alias_input" ] && host_alias="$alias_input"

    local hostname="$remote_host"
    printf 'HostName (IP or FQDN) [%s]: ' "$hostname"
    local hostname_input
    read -r hostname_input
    [ -n "$hostname_input" ] && hostname="$hostname_input"

    local config_user="${remote_user:-$USER}"
    printf 'User [%s]: ' "$config_user"
    local user_input
    read -r user_input
    [ -n "$user_input" ] && config_user="$user_input"

    printf 'Add IdentitiesOnly yes? [y/N] '
    local do_identonly
    read -r do_identonly
    local identonly_line=""
    [[ "$do_identonly" =~ ^[Yy] ]] && identonly_line=$'\n    IdentitiesOnly yes'

    # Determine config file (support config.d/ if Include exists)
    local config_file="$HOME/.ssh/config"
    if [ -d "$HOME/.ssh/config.d" ]; then
      printf 'Write to ~/.ssh/config.d/ instead of ~/.ssh/config? [Y/n] '
      local use_configd
      read -r use_configd
      if [[ ! "$use_configd" =~ ^[Nn] ]]; then
        config_file="$HOME/.ssh/config.d/host_${host_alias}"
        printf 'Config file [%s]: ' "$config_file"
        local cf_input
        read -r cf_input
        [ -n "$cf_input" ] && config_file="$cf_input"
      fi
    fi

    local config_block="
Host $host_alias
    HostName $hostname
    User $config_user
    IdentityFile $key_path${identonly_line}"

    printf '\nWill append to %s:\n' "$config_file"
    printf '%s\n' "$config_block"
    printf '\nConfirm? [Y/n] '
    local confirm
    read -r confirm
    if [[ ! "$confirm" =~ ^[Nn] ]]; then
      printf '%s\n' "$config_block" >> "$config_file"
      chmod 600 "$config_file"
      printf 'Config written.\n'
    fi
  fi

  # ── Done ───────────────────────────────────────────────────────────────
  printf '\n=== Done! ===\n'
  printf 'Test with: ssh %s\n' "${host_alias:-$target}"
  if [[ "$do_scp" =~ ^[Yy] ]]; then
    printf "Test GitHub: ssh %s 'ssh -T git@github.com'\n" "${host_alias:-$target}"
  fi
}
