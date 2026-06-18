# `git push` over SSH fails `Connection closed by … port 443` when SSH_AUTH_SOCK is the Bitwarden agent and you're on a headless / remote session

**Symptoms** (grep this section):
- `git push` (or `ssh -T git@github.com`, or any agent-backed SSH) fails with:
  ```
  Connection closed by 20.205.243.160 port 443
  fatal: Could not read from remote repository.

  Please make sure you have the correct access rights
  and the repository exists.
  ```
- It's **intermittent**: the first push of a sitting works, later ones fail — or
  it fails only when you're driving the box **remotely** (SSH / tmux from another
  machine) and works when you're sitting at its physical screen.
- `echo $SSH_AUTH_SOCK` →
  `/home/<user>/snap/bitwarden/current/.bitwarden-ssh-agent.sock` (or the
  `.deb` / Flatpak path) — i.e. the **Bitwarden desktop app is the SSH agent**.
- `ssh-add -l` lists your Bitwarden-managed key(s), so the key *is* available —
  the failure is at *use* time, not enumeration.

**First seen**: 2026-06-18 on `David-Ubuntu`, pushing the dotfiles repo while
remote-controlling the box over SSH (Bitwarden SSH agent enabled,
`installBitwarden=true`).
**Affects**: any host where `SSH_AUTH_SOCK` points at Bitwarden's agent **and**
Bitwarden's "confirm/authorize each SSH key usage" is on, when the operation runs
somewhere the desktop GUI prompt can't be clicked (SSH session, tmux, cron, CI).
**Status**: not a bug — by design. Pick a workaround below.

## Why

Bitwarden's SSH agent pops a desktop dialog — **"Confirm SSH key usage"** — for
each key use (configurable; see `docs/tutorials/bitwarden_ssh_agent.md:51`). The
approval is cached for a short window, which is why the *first* push of a session
often succeeds and later ones don't. When you're on a remote/headless session the
dialog renders on the box's **physical** display, which you can't reach, so it
goes unanswered → the agent refuses to sign → GitHub drops the connection
(surfacing as `Connection closed by … port 443`, since this repo's remote uses
SSH-over-443 to `github.com`). It is **not** a credentials, network, or GFW
problem — though the identical wording also shows up for real GFW flakiness, so
check `$SSH_AUTH_SOCK` first to disambiguate.

## Fix paths

- **Approve at the physical screen** — the dialog is on the box's own display;
  click it there (or via VNC/RDP). Cheapest one-off.
- **Disable per-use confirmation** — Bitwarden **Settings → SSH agent →** turn
  off the "require confirmation / authorize each use" toggle. The agent then
  signs silently while Bitwarden is unlocked. Trade-off: any local process can
  use your keys while the vault is unlocked — only do this on a trusted box.
- **Forward the agent from a machine you can click on** —
  `ssh -A user@David-Ubuntu`, so the prompt pops on *your* laptop (where
  Bitwarden runs) instead of the remote (`docs/tutorials/bitwarden_ssh_agent.md`
  → "Agent forwarding"). Note: only helps if the *clickable* machine is the one
  running Bitwarden.
- **Use HTTPS + a PAT** for git on headless boxes — bypasses the agent entirely
  for `git` (`git remote set-url origin https://github.com/<user>/<repo>.git`).

## Related

- [docs/tutorials/bitwarden_ssh_agent.md](../docs/tutorials/bitwarden_ssh_agent.md)
  — setup, socket paths per install method, agent forwarding.
- [docs/tools/ssh-agent.md](../docs/tools/ssh-agent.md).
