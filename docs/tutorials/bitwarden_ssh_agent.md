# Bitwarden SSH Agent

Use the Bitwarden desktop app as your SSH agent so private keys never leave the vault.

- **Official docs**: <https://bitwarden.com/help/ssh-agent/>
- **Requires**: Bitwarden desktop >= 2025.1.2, SSH agent enabled in **Settings > Enable SSH agent**

## How It Works

```
┌──────────────┐     SSH_AUTH_SOCK      ┌───────────────────┐
│  ssh / git   │ ───────────────────▶   │  Bitwarden Agent  │
│  (any CLI)   │                        │  (desktop app)    │
└──────────────┘                        └───────────────────┘
                                              │
                                              ▼
                                        Vault (encrypted)
                                        ├─ SSH: jingle
                                        ├─ SSH: azure_vm1
                                        └─ SSH: YetAnotherStupidVM
```

When an SSH client needs a key, it talks to whichever agent `SSH_AUTH_SOCK` points to.
Bitwarden creates a Unix socket file; pointing `SSH_AUTH_SOCK` there makes Bitwarden the agent.
The desktop app prompts you to authorize each key usage (configurable under Settings).

## 1. Import Keys Into Bitwarden

### Via the desktop app

1. Open Bitwarden desktop, click **New > SSH key**.
2. Paste your private key (OpenSSH or PKCS#8 format) using **Import key from clipboard**.
3. The public key and fingerprint are derived automatically.

### Via the CLI script

This repo includes an import script (see [import_ssh_to_bw.sh docs](../scripts/import_ssh_to_bw.sh.md)):

```bash
# Interactive -- pick which keys to import
ssh-to-bitwarden

# Import all keys from ~/.ssh
ssh-to-bitwarden --all

# Preview only
ssh-to-bitwarden --dry-run
```

## 2. Configure SSH_AUTH_SOCK

The socket path depends on how Bitwarden was installed:

| Installation   | macOS socket path                                                                         | Linux socket path                                                       |
|----------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `.dmg`         | `~/.bitwarden-ssh-agent.sock`                                                             | --                                                                      |
| Mac App Store  | `~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock`               | --                                                                      |
| Native / .deb  | --                                                                                        | `~/.bitwarden-ssh-agent.sock`                                           |
| Snap           | --                                                                                        | `~/snap/bitwarden/current/.bitwarden-ssh-agent.sock`                    |
| Flatpak        | --                                                                                        | `~/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock`       |

This repo auto-detects the socket in `~/.config/zsh/tools/95_bitwarden.zsh`.
It tries each candidate path in order and exports `SSH_AUTH_SOCK` for the first socket that exists.
No manual shell configuration is needed if you use the managed zsh config.

## 3. Verify

```bash
# List keys the agent knows about
ssh-add -l

# Expected output (example):
# 3072 SHA256:S93TIv0W2E1B...  SSH: azure_vm1 (RSA)
# 3072 SHA256:B7ZcVqELH0RQ...  SSH: jingle (RSA)
# 3072 SHA256:i+mZs1/NiKo+...  SSH: YetAnotherStupidVM (RSA)

# Test GitHub authentication
ssh -T git@github.com
# Hi daviddwlee84! You've successfully authenticated, ...
```

If `ssh-add -l` returns "The agent has no identities", check:

1. Bitwarden desktop is running and unlocked.
2. SSH agent is enabled in Bitwarden **Settings**.
3. `SSH_AUTH_SOCK` points to the correct socket (`echo $SSH_AUTH_SOCK`).

## 4. Interaction With ~/.ssh/config

### How SSH selects keys

SSH tries keys in this order:

1. Keys specified by `IdentityFile` in `~/.ssh/config` (read directly from disk).
2. Keys offered by the agent (`SSH_AUTH_SOCK`).

This means with Bitwarden as the agent, both sources work together:

- If `IdentityFile ~/.ssh/jingle` exists on disk, SSH uses it directly (no agent involved).
- If the file is missing or its key is rejected, SSH falls back to keys from the Bitwarden agent.

### Recommended config patterns

#### Keep IdentityFile (local file primary, Bitwarden fallback)

This is the safest migration path. Your existing config works unchanged.
If you ever delete local key files, Bitwarden agent seamlessly takes over:

```ssh-config
# ~/.ssh/config

Host github.com
    HostName github.com
    IdentityFile ~/.ssh/jingle      # used if file exists on disk
                                     # Bitwarden agent is fallback

Host azure
    HostName davidlee.japaneast.cloudapp.azure.com
    User daviddwlee84
    Port 22
    IdentityFile ~/.ssh/YetAnotherStupidVM
```

#### Agent-only (no local key files needed)

If you want to fully rely on Bitwarden and remove private keys from disk:

```ssh-config
# ~/.ssh/config

Host github.com
    HostName github.com
    # No IdentityFile -- agent provides the right key automatically

Host azure
    HostName davidlee.japaneast.cloudapp.azure.com
    User daviddwlee84
    Port 22
    # No IdentityFile -- agent provides the right key automatically
```

SSH tries each key from the agent until the server accepts one.

#### Pinning a specific key via fingerprint (agent-only, explicit)

If you have many keys in the agent and want to avoid trial-and-error,
use `IdentityFile` with the key's public key file (`.pub` files can remain on disk safely):

```ssh-config
Host github.com
    HostName github.com
    IdentityFile ~/.ssh/jingle.pub
    IdentitiesOnly yes
```

With `IdentitiesOnly yes`, SSH will **only** request the matching key from the agent
(identified by the public key) and won't try others. This is useful when servers
limit authentication attempts.

### What to avoid

```ssh-config
# DON'T combine IdentitiesOnly with no IdentityFile when using an agent
Host example
    IdentitiesOnly yes
    # No IdentityFile = no keys will be tried at all!
```

`IdentitiesOnly yes` without an `IdentityFile` disables agent key offering entirely.

## 5. Git Commit Signing With SSH

Bitwarden SSH keys can also sign Git commits:

```bash
# Configure Git to use SSH signing
git config --global gpg.format ssh
git config --global user.signingkey "ssh-rsa AAAAB3Nza..."  # your public key
git config --global commit.gpgsign true
```

On GitHub, add the same public key as a **Signing Key** (separate from the Authentication Key)
under **Settings > SSH and GPG keys**.

## 6. SSH Agent Forwarding

Use `-A` to forward the Bitwarden agent to a remote host:

```bash
ssh -A user@remote-host
```

Or in `~/.ssh/config`:

```ssh-config
Host myserver
    HostName 192.168.1.100
    User admin
    ForwardAgent yes
```

The remote host can then use your Bitwarden-managed keys to authenticate onward
(e.g., `git pull` on the remote server) without your private keys ever leaving your machine.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ssh-add -l` returns "no identities" | Bitwarden locked or agent disabled | Unlock Bitwarden, enable SSH agent in Settings |
| `ssh-add -l` returns "connection refused" | Wrong socket path | Check `echo $SSH_AUTH_SOCK` and `ls -la` the path |
| SSH uses wrong key / too many auth failures | Too many agent keys tried before the right one | Add `IdentityFile` with `.pub` and `IdentitiesOnly yes` |
| Git commit signing fails | `user.signingkey` not set or wrong | Verify with `git config --global user.signingkey` |
| Agent works in terminal but not in IDE | IDE uses its own environment | Configure `SSH_AUTH_SOCK` in IDE settings or launch IDE from terminal |

## Related

- [Bitwarden SSH Agent official docs](https://bitwarden.com/help/ssh-agent/)
- [import_ssh_to_bw.sh](../scripts/import_ssh_to_bw.sh.md) -- Bulk import SSH keys to Bitwarden
- `~/.config/zsh/tools/95_bitwarden.zsh` -- Auto-detection of Bitwarden SSH agent socket
