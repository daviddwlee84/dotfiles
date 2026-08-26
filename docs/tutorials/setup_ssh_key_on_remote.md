# Setup SSH Key on Remote Machine

Copy a local SSH key to a remote machine (e.g. Raspberry Pi) for both SSH login and GitHub access.

## Prerequisites

- SSH access to the remote machine (password auth initially)
- The public key added to your GitHub account at <https://github.com/settings/keys>

## 0. Create an SSH Key

### Choosing an algorithm

| Algorithm | Command | Notes |
|-----------|---------|-------|
| **Ed25519** | `ssh-keygen -t ed25519` | Recommended. Fast, secure, short keys. Works everywhere (OpenSSH >= 6.5). |
| **Ed25519-SK** | `ssh-keygen -t ed25519-sk` | Hardware-bound (FIDO2 / YubiKey). Requires physical touch to sign. |
| **ECDSA-SK** | `ssh-keygen -t ecdsa-sk` | FIDO2 fallback for older YubiKeys that don't support Ed25519-SK. |
| **RSA (4096)** | `ssh-keygen -t rsa -b 4096` | Legacy compatibility only. Use if connecting to very old systems. |
| **ECDSA** | `ssh-keygen -t ecdsa -b 521` | Less common; no advantage over Ed25519. |

**TL;DR**: Use `ed25519` unless you need hardware key (`ed25519-sk`) or legacy compat (`rsa`).

### Generating the key

```bash
# Basic (interactive prompts for path and passphrase)
ssh-keygen -t ed25519 -C "your_email@example.com"

# Explicit file path and comment
ssh-keygen -t ed25519 -f ~/.ssh/<key> -C "description or email"

# With a YubiKey (requires the key plugged in)
ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sk -C "yubikey"
```

### Passphrase or not?

| Scenario | Passphrase? | Why |
|----------|-------------|-----|
| Personal machine, full-disk encryption | Optional | Disk encryption already protects the file |
| Shared / multi-user machine | Yes | Prevents other users/processes from using your key |
| CI/CD, automation, headless server | No | No human to type it; use file permissions + secrets manager |
| High-security / compliance | Yes | Defense in depth; combine with SSH agent so you type it once |

> **Tip**: You can change or remove a passphrase later without regenerating the key:
> ```bash
> ssh-keygen -p -f ~/.ssh/<key>
> ```

### Managing keys after creation

#### Plain file (simplest)

Keys live as files in `~/.ssh/`. You specify them explicitly in `~/.ssh/config`:

```
Host github.com
    IdentityFile ~/.ssh/<key>
```

Pros: simple, portable. Cons: key file on disk, must copy to each machine.

#### SSH agent

Load the key into an agent so you only type the passphrase once per session:

```bash
# Start agent (this repo does this automatically, see docs/tools/ssh-agent.md)
eval "$(ssh-agent -s)"

# Add key (prompts for passphrase if set)
ssh-add ~/.ssh/<key>

# macOS: store passphrase in Keychain (survives reboots)
ssh-add --apple-use-keychain ~/.ssh/<key>
```

#### Bitwarden SSH Agent

Store the key in Bitwarden vault; the desktop app acts as the SSH agent. No key file on disk after initial import.

See [Bitwarden SSH Agent tutorial](./bitwarden_ssh_agent.md) for full setup.

#### 1Password / other password managers

Similar concept to Bitwarden -- the app provides an SSH agent socket. Consult your password manager's docs.

#### YubiKey (FIDO2)

The private key **never leaves the hardware**. The `-sk` key types (`ed25519-sk`, `ecdsa-sk`) generate a key handle stored in `~/.ssh/` but the actual signing happens on the YubiKey. You need the YubiKey plugged in for every SSH operation.

#### Comparison

| Method | Key on disk? | Portable across machines? | Passphrase needed each session? |
|--------|-------------|--------------------------|-------------------------------|
| Plain file | Yes | Copy manually | Every time (or no passphrase) |
| SSH agent | Yes (loaded into memory) | Copy key, agent auto-loads | Once per session |
| Bitwarden / 1Password | No (after import) | Synced via vault | Unlock vault once |
| YubiKey | Handle only | Carry the physical key | Touch per operation |

### `IdentitiesOnly yes`

By default, the SSH client offers **all keys** from the agent to the server, one by one, before trying `IdentityFile`. This causes problems when:

1. **Too many keys in agent** -- Most servers allow only 5-6 auth attempts. If your agent holds 8+ keys, the server rejects you with `Too many authentication failures` before it ever tries the right one.
2. **Wrong key used for wrong host** -- Without restriction, SSH might authenticate to a server with an unintended key (e.g. your personal key used on a work server).
3. **Security / audit** -- You want to guarantee exactly which key is used for each host.

Add `IdentitiesOnly yes` to your SSH config to make SSH **only** use the key specified by `IdentityFile`, ignoring everything else in the agent:

```
# Per-host
Host github.com
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes

# Or globally (recommended if you have many keys)
Host *
    IdentitiesOnly yes
```

> **Note**: With `IdentitiesOnly yes`, every host entry **must** have an `IdentityFile` -- SSH won't fall back to agent keys. If you use a password manager agent (Bitwarden/1Password), you typically do NOT want this globally since the agent is the only source of keys.

| Scenario | `IdentitiesOnly` | Why |
|----------|-------------------|-----|
| Few keys, single agent | No (default) | Agent tries them all, no issue |
| Many keys in agent (5+) | **Yes** | Prevent "too many failures" |
| Multiple GitHub/GitLab accounts | **Yes** | Force correct key per host |
| Bitwarden/1Password agent only | No | Agent IS the identity source |
| Mix of file keys + agent keys | **Yes** per host | Explicit control |

## 1. Enable SSH Login to Remote

### Standard key file

```bash
ssh-copy-id -i ~/.ssh/<key>.pub user@remote
```

This appends the public key to `~/.ssh/authorized_keys` on the remote.

### YubiKey / hardware security key

If your key lives on a YubiKey (FIDO2 or PIV), there's no private key file on disk -- only the `.pub` file or the agent knows about it.

```bash
# If you have the .pub file (ed25519-sk / ecdsa-sk)
ssh-copy-id -i ~/.ssh/id_ed25519_sk.pub user@remote

# If the key is only in your agent (YubiKey PIV, gpg-agent, etc.)
# ssh-copy-id will automatically use keys from the agent
ssh-copy-id user@remote
```

### SSH agent (Bitwarden, 1Password, gpg-agent, etc.)

When your keys are managed by an SSH agent and there's no `.pub` file on disk:

```bash
# List keys the agent currently holds
ssh-add -L

# ssh-copy-id picks up agent keys automatically
ssh-copy-id user@remote

# Or pipe a specific key from the agent
ssh-add -L | grep "<key comment or type>" | ssh user@remote 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
```

> **Note**: Make sure `SSH_AUTH_SOCK` points to the correct agent.
> See [SSH Agent Fallback](../tools/ssh-agent.md) for how this repo manages `SSH_AUTH_SOCK`.

Then add to your local `~/.ssh/config`:

```
Host rpi
    HostName <IP or hostname>
    User <user>
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes          # optional: use only this key, ignore agent
```

Verify: `ssh rpi` should connect without a password.

## 2. Copy the Key Pair to Remote

```bash
scp ~/.ssh/<key> ~/.ssh/<key>.pub rpi:~/.ssh/
ssh rpi 'chmod 600 ~/.ssh/<key> && chmod 644 ~/.ssh/<key>.pub'
```

## 3. Configure GitHub SSH on Remote

```bash
ssh rpi 'cat >> ~/.ssh/config << EOF

Host github.com
    IdentityFile ~/.ssh/<key>
EOF'
ssh rpi 'chmod 600 ~/.ssh/config'
```

## 4. Switch Git Remote from HTTPS to SSH

```bash
ssh rpi 'cd /path/to/repo && git remote set-url origin git@github.com:<user>/<repo>.git'
```

General pattern: `https://github.com/<user>/<repo>.git` → `git@github.com:<user>/<repo>.git`

## 5. Verify

```bash
# Test GitHub SSH auth
ssh rpi 'ssh -T git@github.com'
# Expected: "Hi <user>! You've successfully authenticated..."

# Test git push
ssh rpi 'cd /path/to/repo && git push'
```

## Automation: `ssh-setup-remote`

This repo includes a shell function that walks through all the steps above interactively:

```bash
ssh-setup-remote user@hostname
```

It will prompt you to:

1. **Select or create** an SSH key (algorithm, name, passphrase)
2. **ssh-copy-id** the public key to enable passwordless login
3. **Copy the key pair** to the remote (optional, for GitHub access)
4. **Add GitHub SSH config** on the remote (optional)
5. **Wire the key into your local `~/.ssh/config`** — the wizard recognizes two cases:
   - If the alias is **already configured** (it follows `Include ~/.ssh/config.d/*` recursively to
     find the right file), it **adds the `IdentityFile` into the existing `Host` block in place**
     instead of appending a duplicate. If the block already has an `IdentityFile`, it asks whether
     to *replace* / *add another* / *skip*, and re-running with the same key is a no-op.
   - If it's a **new host** (e.g. `user@ip`), it appends a fresh alias block (to `~/.ssh/config`
     or a `~/.ssh/config.d/` drop-in) with an optional `IdentitiesOnly yes`. When it writes a
     drop-in but your `~/.ssh/config` lacks the `Include` line, it offers to add it so the entry
     actually loads.

   > In-place editing uses `python3`; if it is unavailable the wizard falls back to the
   > append-only behavior.

Source: `~/.config/shell/96_ssh_setup.sh`. A Windows PowerShell counterpart with the same
command name and the same flow ships in the companion `dotfiles-windows` repo.

### ProxyJump chains

`ssh(1)` tunnels transparently through a `ProxyJump` host, so a naive setup on the final target
alone leaves the jump host asking for a password on every connection — the jump host never got a
key. `ssh-setup-remote` resolves the target's **full jump chain first** (recursively — a jump host
can have its own `ProxyJump`) and repeats the whole flow for every hop, outermost first:

```
Host zr-windows
    HostName 61.169.38.122
    User zhurun

Host zr
    HostName 10.168.11.54
    User hongxing
    ProxyJump zr-windows
```

```console
$ ssh-setup-remote zr

=== SSH Key Setup for zr ===

ProxyJump chain detected: zr-windows -> zr
Each hop needs its own key on its own authorized_keys — ProxyJump only
forwards TCP, so the jump host never sees your private key.

========================================
[1/2] zr-windows (jump)
========================================
...
========================================
[2/2] zr (target)
========================================
...
```

A jump host only gets steps 1 and 3 (install the key, wire local config) — ProxyJump
authenticates end-to-end from your machine, so a jump host never needs the private key, and step 2
(copying the key pair) only runs for the final target. Already-passwordless hops are detected and
offered a skip.

### A private key with no `.pub`

If a key's public half is missing (a partial copy from another machine, an agent-only import), it
used to pass the existence check silently and only fail later inside `ssh-copy-id` with
`failed to open ID file '…/key.pub': No such file or directory`. The wizard now notices this right
after key selection and offers to regenerate it:

```console
No public key next to /Users/you/.ssh/some_key.
Regenerate it with `ssh-keygen -y`? [Y/n]
```

The public key is always derivable from the private key, so this is a safe, lossless repair — you
can also do it manually ahead of time: `ssh-keygen -y -f ~/.ssh/some_key > ~/.ssh/some_key.pub`.

## Troubleshooting

### Remote Host Identification Has Changed

If you see `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` when connecting, the server's host key no longer matches what's stored in `~/.ssh/known_hosts`. This commonly happens after reinstalling the OS or reprovisioning a server at the same IP.

Remove the old key and reconnect:

```bash
ssh-keygen -R <host>
ssh user@<host>   # accept the new key when prompted
```

The error message tells you the offending line number (e.g. `Offending ECDSA key in ~/.ssh/known_hosts:89`), but `ssh-keygen -R` handles removal by hostname/IP automatically.
