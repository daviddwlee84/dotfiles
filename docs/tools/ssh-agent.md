# SSH Agent

Automatic SSH agent management with Bitwarden-first fallback to `ssh-agent`.

**Config file**: `~/.config/zsh/tools/94_ssh_agent.zsh`

---

## Concepts

### What is an SSH key pair?

SSH uses asymmetric cryptography — a **private key** (kept secret) and a **public key** (shared freely).

```
~/.ssh/id_ed25519      ← private key  (never share this)
~/.ssh/id_ed25519.pub  ← public key   (paste into servers / GitHub)
```

When you connect to a server, SSH proves your identity by doing a cryptographic challenge using your private key. The server verifies it with your public key in `~/.ssh/authorized_keys`.

**Key types** (prefer ed25519 for new keys):

| Type | Strength | Notes |
|------|----------|-------|
| `ed25519` | Modern, recommended | Small key, fast, secure |
| `rsa` (4096-bit) | Widely compatible | Older; still fine if already in use |
| `ecdsa` | Good | Less common |

Generate a new key:
```bash
ssh-keygen -t ed25519 -C "your@email.com"
# Saves to ~/.ssh/id_ed25519 and ~/.ssh/id_ed25519.pub
```

### What is a passphrase?

A passphrase encrypts your private key file on disk. Without it, anyone who gets the file can use it.

**Trade-off:**
- No passphrase: convenient, but risky if your machine is compromised
- With passphrase: secure, but SSH asks for it every time you use the key — unless you use an **SSH agent**

### What is an SSH agent?

An SSH agent is a background process that holds your **decrypted private keys in memory**. When SSH needs to sign a challenge, it asks the agent — so you only enter the passphrase **once per login session**, not every connection.

```
┌───────────┐  challenge  ┌───────────────┐  sign  ┌─────────────┐
│  ssh/git  │ ──────────▶ │   ssh-agent   │ ──────▶ │  decrypted  │
│  client   │ ◀────────── │  (in memory)  │         │   key copy  │
└───────────┘  signature  └───────────────┘         └─────────────┘
        ↑
        └── "Connected!"
```

Communication happens through a **Unix socket** pointed to by `SSH_AUTH_SOCK`:

```bash
echo $SSH_AUTH_SOCK    # e.g. /run/user/1000/ssh-agent/agent.sock
ssh-add -l             # list keys currently held by the agent
ssh-add ~/.ssh/id_rsa  # manually add a key (will ask for passphrase once)
```

### How auto-loading keys works (and the passphrase prompt)

When the fallback `ssh-agent` starts and has no keys, `_maybe_add_keys` in
`94_ssh_agent.zsh` tries to add common key files automatically:

```zsh
# key_names list: id_ed25519, id_rsa, id_ecdsa, jingle
SSH_ASKPASS_REQUIRE=never ssh-add -q "$kf" 2>/dev/null
```

**`SSH_ASKPASS_REQUIRE=never`** tells ssh-add: "don't prompt for a passphrase at
all — if you need one, just fail silently." This means:

- Keys **without** a passphrase → auto-loaded into the agent silently
- Keys **with** a passphrase → skipped (no prompt at login)

> **Why not `</dev/null`?** `ssh-add` bypasses stdin and opens `/dev/tty` directly
> for passphrase input, so redirecting stdin has no effect. `SSH_ASKPASS_REQUIRE`
> is the correct mechanism (available since OpenSSH 8.4, 2020).

**To manually load a key with a passphrase** (once per session):
```bash
ssh-add ~/.ssh/id_rsa
# Enter passphrase: ••••••
# The key is now in the agent for the rest of this login session
```

---

## How It Works

Every new interactive shell runs the following fallback chain:

```
1. Bitwarden SSH agent socket?  ──yes──▶  Use it (export SSH_AUTH_SOCK)
         │ no
         ▼
2. Existing SSH_AUTH_SOCK works? ──yes──▶  Keep it (forwarded agent, systemd, gnome-keyring, etc.)
         │ no
         ▼
3. Persistent ssh-agent         ──────▶  Spawn once, reuse across shells
         │                                Auto-load passphrase-free keys from ~/.ssh/
         ▼
   SSH_AUTH_SOCK is set and ready
```

### Step 1: Bitwarden SSH Agent

Iterates known Bitwarden socket paths (see [bitwarden_ssh_agent.md](../tutorials/bitwarden_ssh_agent.md#2-configure-ssh_auth_sock) for the full table).
Each candidate is probed with a **2-second timeout** on `ssh-add -l`:

- Socket doesn't exist (`-S` test fails) → skip immediately
- Socket exists but `ssh-add -l` **times out** (agent hung) → skip
- Socket responds with "agent refused operation" (Bitwarden locked/disabled) → skip
- Socket responds with keys or "no identities" → **use it**

This means a locked/crashed Bitwarden won't block shell startup.

### Step 2: Existing Agent

Respects any `SSH_AUTH_SOCK` already set by the environment:
- SSH agent forwarding (`ssh -A`)
- systemd `ssh-agent.service`
- GNOME Keyring
- GPG agent with SSH support

If the current socket is valid and responding, it is kept as-is.

### Step 3: Persistent ssh-agent

When neither Bitwarden nor an existing agent is available, a standard `ssh-agent` is spawned with a **fixed socket path**:

```
$XDG_RUNTIME_DIR/ssh-agent/agent.sock   (Linux, typical: /run/user/1000/ssh-agent/)
$HOME/.cache/ssh-agent/agent.sock        (fallback when XDG_RUNTIME_DIR is unset)
```

Key properties:
- **One agent per user**: all shells share the same socket, no orphan agents.
- **Survives shell restarts**: opening a new terminal reuses the existing agent.
- **Auto-loads keys**: on first use (when agent has no identities), automatically runs `ssh-add` for common key names: `id_ed25519`, `id_rsa`, `id_ecdsa`, `jingle`. Keys with passphrases are skipped silently.

---

## SSH Config Basics

`~/.ssh/config` lets you define aliases and per-host settings so you don't have to
type long options every time.

### Structure

```ssh-config
Host <alias>
    HostName <real hostname or IP>
    User <username>
    Port <port>          # default: 22
    IdentityFile <path>  # which key to use
```

### Common patterns

#### Simple alias

```ssh-config
Host rpi
    HostName 100.64.157.9   # Tailscale IP or domain
    User keithkslee
```

Now `ssh rpi` works instead of `ssh keithkslee@100.64.157.9`.

#### Specify which key to use

```ssh-config
Host github.com
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes   # don't try other agent keys
```

`IdentitiesOnly yes` prevents SSH from offering every key in the agent. Useful when
a server rejects too many auth attempts.

#### Agent forwarding

```ssh-config
Host rpi
    HostName 100.64.157.9
    User keithkslee
    ForwardAgent yes   # your local agent keys work on the remote host
```

With `ForwardAgent yes`, once you're on the remote machine, you can `git pull`,
`ssh` to other servers, etc. using your local keys — **without copying private
keys to the remote machine**.

> **Security note**: only forward your agent to hosts you trust. Anyone with root
> on the remote machine can use your forwarded agent socket.

#### Jump host (ProxyJump)

If a server is only reachable through a bastion/jump host:

```ssh-config
Host bastion
    HostName bastion.example.com
    User admin

Host internal-server
    HostName 10.0.0.5
    User app
    ProxyJump bastion   # SSH through bastion automatically
```

`ssh internal-server` will transparently connect through `bastion`.

#### Common options reference

| Option | What it does |
|--------|-------------|
| `HostName` | Real hostname/IP (alias goes in `Host`) |
| `User` | Remote username |
| `Port` | SSH port (default 22) |
| `IdentityFile` | Path to private key (`~/.ssh/id_ed25519`) |
| `IdentitiesOnly yes` | Only use specified keys, not all agent keys |
| `ForwardAgent yes` | Forward local SSH agent to remote |
| `ProxyJump <host>` | Connect through a jump host |
| `ServerAliveInterval 60` | Send keepalive every 60s (prevents timeout) |
| `StrictHostKeyChecking no` | Skip host key verification (use for known-safe internal hosts only) |

---

## Debugging

```bash
# Which agent is active?
echo $SSH_AUTH_SOCK

# Is the agent responding?
ssh-add -l

# Which strategy was selected?
# Re-source with verbose output:
zsh -x -c 'source ~/.config/zsh/tools/94_ssh_agent.zsh' 2>&1 | grep SSH_AUTH_SOCK

# Force fallback (skip Bitwarden) for testing:
unset SSH_AUTH_SOCK
source ~/.config/zsh/tools/94_ssh_agent.zsh
echo $SSH_AUTH_SOCK

# Verbose SSH connection (shows which key is being tried)
ssh -v user@host
ssh -vvv user@host  # more verbose
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ssh-add -l` → "Could not open connection" | No agent running, script didn't execute | Check `source ~/.config/zsh/tools/94_ssh_agent.zsh` runs without error |
| Bitwarden socket exists but fallback is used | Bitwarden locked or agent disabled | Unlock Bitwarden, enable SSH agent in **Settings** |
| Multiple ssh-agent processes | Old agents from before this script | `pkill ssh-agent` then open a new shell |
| Keys not auto-loaded | Key filename not in the list | Add the filename to `key_names` array in `94_ssh_agent.zsh` |
| Agent dies after reboot | XDG_RUNTIME_DIR is tmpfs (expected) | Normal — agent respawns on next shell |
| Passphrase prompt appears at login | Key with passphrase in `~/.ssh/`, OpenSSH < 8.4 | `SSH_ASKPASS_REQUIRE=never` requires OpenSSH 8.4+; upgrade or remove the key from `key_names` |
| `Permission denied (publickey)` | Public key not in server's `authorized_keys` | Run `ssh-copy-id user@host` or append `~/.ssh/id_*.pub` to `~/.ssh/authorized_keys` on server |
| SSH asks for password despite having a key | Wrong key / key not in agent | `ssh-add -l` to check; `ssh -v user@host` to trace |

## Customization

### Adding more key files to auto-load

Edit the `key_names` array in `94_ssh_agent.zsh`:

```zsh
local -a key_names=(id_ed25519 id_rsa id_ecdsa jingle my_work_key)
```

### Disabling auto-load entirely

Comment out the `_maybe_add_keys` call inside `_fallback_ssh_agent`.

### Using systemd ssh-agent instead of the built-in fallback

If you prefer systemd to manage the agent:

```bash
# Create the service
systemctl --user enable --now ssh-agent

# Set SSH_AUTH_SOCK in environment
echo 'export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"' >> ~/.zshrc.adhoc
```

The fallback script's step 2 will detect this and skip step 3.

## Related

- [Bitwarden SSH Agent tutorial](../tutorials/bitwarden_ssh_agent.md) — full setup guide for Bitwarden as agent
- `~/.config/zsh/tools/94_ssh_agent.zsh` — SSH agent auto-detection and fallback
- `~/.config/zsh/tools/95_bitwarden.zsh` — Bitwarden CLI zsh completion
