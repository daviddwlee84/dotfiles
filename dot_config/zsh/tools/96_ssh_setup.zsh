# 96_ssh_setup.zsh - Interactive SSH key setup for remote machines
#
# Usage: ssh-setup-remote [user@]host
#
# Walks through: create key → ssh-copy-id → copy key to remote → add SSH config entries.
# See docs/tutorials/setup_ssh_key_on_remote.md for the full tutorial.

ssh-setup-remote() {
  emulate -L zsh
  setopt localoptions pipefail

  local usage="Usage: ssh-setup-remote [user@]host"
  if (( $# != 1 )); then
    print -u2 -- "$usage"
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
  print "\n=== SSH Key Setup for $target ==="

  local key_path=""
  local create_new=""

  print "\nExisting keys in ~/.ssh/:"
  local -a existing_keys=()
  for f in ~/.ssh/*.pub(N); do
    existing_keys+=("${f%.pub}")
    print "  ${f%.pub}"
  done

  if (( ${#existing_keys} > 0 )); then
    print -n "\nUse an existing key? [Y/n] "
    read -r create_new
    if [[ "$create_new" =~ ^[Nn] ]]; then
      create_new="yes"
    else
      print -n "Enter key path (without .pub): "
      read -r key_path
      # Expand ~ manually
      key_path="${key_path/#\~/$HOME}"
      if [[ ! -f "$key_path" && ! -f "${key_path}.pub" ]]; then
        print -u2 "Key not found: $key_path"
        return 1
      fi
    fi
  else
    print "  (none found)"
    create_new="yes"
  fi

  # ── Step 0b: Create new key ────────────────────────────────────────────
  if [[ "$create_new" == "yes" ]]; then
    print "\n--- Create new SSH key ---"

    # Algorithm
    local algo="ed25519"
    print -n "Algorithm [ed25519] (ed25519/ed25519-sk/rsa): "
    read -r algo_input
    [[ -n "$algo_input" ]] && algo="$algo_input"

    # Key name
    local key_name="id_${algo}_${remote_host}"
    print -n "Key name [$key_name]: "
    read -r name_input
    [[ -n "$name_input" ]] && key_name="$name_input"
    key_path="$HOME/.ssh/$key_name"

    if [[ -f "$key_path" ]]; then
      print -u2 "Key already exists: $key_path"
      return 1
    fi

    # Comment
    local comment="${USER}@$(hostname -s) -> ${remote_host}"
    print -n "Comment [$comment]: "
    read -r comment_input
    [[ -n "$comment_input" ]] && comment="$comment_input"

    # Passphrase
    local passphrase_flag=()
    print -n "Set a passphrase? [y/N] "
    read -r use_pass
    if [[ "$use_pass" =~ ^[Yy] ]]; then
      # Let ssh-keygen prompt for it
      passphrase_flag=()
    else
      passphrase_flag=(-N "")
    fi

    # Generate
    local keygen_args=(-t "$algo" -f "$key_path" -C "$comment" "${passphrase_flag[@]}")
    [[ "$algo" == "rsa" ]] && keygen_args+=(-b 4096)

    print "\n> ssh-keygen ${keygen_args[*]}"
    ssh-keygen "${keygen_args[@]}" || return 1
    print "\nKey created: $key_path"
  fi

  # ── Step 1: ssh-copy-id ────────────────────────────────────────────────
  print "\n--- Copy public key to $target ---"
  print -n "Run ssh-copy-id to enable passwordless login? [Y/n] "
  read -r do_copy
  if [[ ! "$do_copy" =~ ^[Nn] ]]; then
    print "\n> ssh-copy-id -i ${key_path}.pub $target"
    ssh-copy-id -i "${key_path}.pub" "$target" || {
      print -u2 "ssh-copy-id failed. You may need to enter the remote password."
      return 1
    }
  fi

  # ── Step 2: Copy key pair to remote ────────────────────────────────────
  print "\n--- Copy key pair to remote ---"
  print "This lets the remote machine use the same key (e.g. for GitHub)."
  print -n "Copy private+public key to $target:~/.ssh/? [y/N] "
  read -r do_scp
  if [[ "$do_scp" =~ ^[Yy] ]]; then
    local key_basename="${key_path:t}"
    print "\n> scp $key_path ${key_path}.pub $target:~/.ssh/"
    scp "$key_path" "${key_path}.pub" "$target:~/.ssh/" || return 1
    ssh "$target" "chmod 600 ~/.ssh/$key_basename && chmod 644 ~/.ssh/${key_basename}.pub"
    print "Key copied and permissions set."

    # Configure GitHub on remote
    print -n "\nAdd GitHub SSH config on remote? [y/N] "
    read -r do_github
    if [[ "$do_github" =~ ^[Yy] ]]; then
      ssh "$target" "mkdir -p ~/.ssh && cat >> ~/.ssh/config" <<EOF

Host github.com
    IdentityFile ~/.ssh/$key_basename
EOF
      ssh "$target" "chmod 600 ~/.ssh/config"
      print "GitHub SSH config added on remote."
    fi
  fi

  # ── Step 3: Local SSH config ───────────────────────────────────────────
  print "\n--- Local SSH config ---"
  print -n "Add host alias to local ~/.ssh/config? [Y/n] "
  read -r do_config
  if [[ ! "$do_config" =~ ^[Nn] ]]; then
    local host_alias="$remote_host"
    print -n "Host alias [$host_alias]: "
    read -r alias_input
    [[ -n "$alias_input" ]] && host_alias="$alias_input"

    local hostname="$remote_host"
    print -n "HostName (IP or FQDN) [$hostname]: "
    read -r hostname_input
    [[ -n "$hostname_input" ]] && hostname="$hostname_input"

    local config_user="${remote_user:-$USER}"
    print -n "User [$config_user]: "
    read -r user_input
    [[ -n "$user_input" ]] && config_user="$user_input"

    print -n "Add IdentitiesOnly yes? [y/N] "
    read -r do_identonly
    local identonly_line=""
    [[ "$do_identonly" =~ ^[Yy] ]] && identonly_line=$'\n    IdentitiesOnly yes'

    # Determine config file (support config.d/ if Include exists)
    local config_file="$HOME/.ssh/config"
    if [[ -d "$HOME/.ssh/config.d" ]]; then
      print -n "Write to ~/.ssh/config.d/ instead of ~/.ssh/config? [Y/n] "
      read -r use_configd
      if [[ ! "$use_configd" =~ ^[Nn] ]]; then
        config_file="$HOME/.ssh/config.d/host_${host_alias}"
        print -n "Config file [$config_file]: "
        read -r cf_input
        [[ -n "$cf_input" ]] && config_file="$cf_input"
      fi
    fi

    local config_block="
Host $host_alias
    HostName $hostname
    User $config_user
    IdentityFile $key_path${identonly_line}"

    print "\nWill append to $config_file:"
    print "$config_block"
    print -n "\nConfirm? [Y/n] "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Nn] ]]; then
      print "$config_block" >> "$config_file"
      chmod 600 "$config_file"
      print "Config written."
    fi
  fi

  # ── Done ───────────────────────────────────────────────────────────────
  print "\n=== Done! ==="
  print "Test with: ssh ${host_alias:-$target}"
  if [[ "$do_scp" =~ ^[Yy] ]]; then
    print "Test GitHub: ssh ${host_alias:-$target} 'ssh -T git@github.com'"
  fi
}
