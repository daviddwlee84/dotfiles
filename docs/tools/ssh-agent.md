# SSH Agent Fallback

Automatic SSH agent management with Bitwarden-first fallback to `ssh-agent`.

**Config file**: `~/.config/zsh/tools/94_ssh_agent.zsh`

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
         │                                Auto-load keys from ~/.ssh/
         ▼
   SSH_AUTH_SOCK is set and ready
```

### Step 1: Bitwarden SSH Agent

Iterates known Bitwarden socket paths (see [bitwarden_ssh_agent.md](../tutorials/bitwarden_ssh_agent.md#2-configure-ssh_auth_sock) for the full table).
Each candidate is probed with a **2-second timeout** on `ssh-add -l`:

- Socket doesn't exist (`-S` test fails) -> skip immediately
- Socket exists but `ssh-add -l` **times out** (agent hung) -> skip
- Socket responds with "agent refused operation" (Bitwarden locked/disabled) -> skip
- Socket responds with keys or "no identities" -> **use it**

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
- **Auto-loads keys**: on first use (when agent has no identities), automatically runs `ssh-add` for common key names: `id_ed25519`, `id_rsa`, `id_ecdsa`, `jingle`.

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
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ssh-add -l` → "Could not open connection" | No agent running, script didn't execute | Check `source ~/.config/zsh/tools/94_ssh_agent.zsh` runs without error |
| Bitwarden socket exists but fallback is used | Bitwarden locked or agent disabled | Unlock Bitwarden, enable SSH agent in **Settings** |
| Multiple ssh-agent processes | Old agents from before this script | `pkill ssh-agent` then open a new shell |
| Keys not auto-loaded | Key filename not in the list | Add the filename to `key_names` array in `94_ssh_agent.zsh` |
| Agent dies after reboot | XDG_RUNTIME_DIR is tmpfs (expected) | Normal — agent respawns on next shell |

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

- [Bitwarden SSH Agent tutorial](../tutorials/bitwarden_ssh_agent.md) — full setup guide
- `~/.config/zsh/tools/95_bitwarden.zsh` — Bitwarden CLI completion (separate from agent)
