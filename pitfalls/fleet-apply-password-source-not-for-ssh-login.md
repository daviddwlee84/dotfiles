# `fleet-status` reports `unreachable` even though `ssh <host>` works interactively

**Symptoms** (grep this section):
- `just fleet-status` shows a host as ✗ `unreachable` with note like
  `PermissionDenied: Permission denied for user <user> on host <ip>`
- `just fleet-apply --hosts <host>` fails the same way at the readiness preflight
- Manually running `ssh <host>` (or `ssh <ssh_alias>`) succeeds — but **prompts
  for a password** before letting you in
- Other hosts in the same `~/.config/fleet/machines.toml` succeed (they all use
  SSH key / `ssh-agent` / 1Password agent auth)
- The host's inventory entry has a `password_source = { type = "plain", value = "..." }`
  (or `bitwarden` / `prompt`) — and you reasonably assumed that covers SSH login

**First seen**: 2026-05-08, on `zyc_friend` (an IDC server reachable only via
password auth). User had set `password_source = { type = "plain", ... }` and
expected `fleet-status` / `fleet-apply` to use that for the SSH login.

**Affects**: any host where `~/.ssh/config` doesn't yield a usable key (no
`IdentityFile`, no agent forward, key not authorised on remote, password-only
sshd policy).

## Root cause

In `scripts/fleet_apply.py`, `password_source` is **only** consumed by
`_resolve_passwords()` (~line 203) to populate `Host.sudo_password`, which is
then written to a 0600 temp file on the remote and exported as
`CHEZMOI_SUDO_PASSWORD_FILE` (see `build_remote_command()` ~line 426). That env
var is picked up by `scripts/lib/sudo_shared.sh` → `sudo_session_init` to skip
the `/dev/tty` prompt during chezmoi's `run_*` scripts.

**SSH login itself uses `subprocess` → `ssh -o BatchMode=yes` (effectively)
with no `sshpass` involvement.** When key auth fails, sshd asks for a password,
`BatchMode` forbids it, the connection dies with `Permission denied`, and the
host is classified `unreachable` by `_classify_readiness()` (~line 2007).

So the password schema works at two completely different stages:

| Stage | Auth mechanism | Reads `password_source`? |
|---|---|---|
| SSH login (transport) | key / agent only | ❌ NO |
| Remote `sudo` (after login) | `CHEZMOI_SUDO_PASSWORD_FILE` from `password_source` | ✅ YES |

The schema doc (`dot_config/fleet/create_private_machines.toml.tmpl` lines
49–54) labels `type = "plain"` as "last resort — relies on file mode 0600",
which reads as if it covers everything. It doesn't say *what* it covers.

## Why it's designed this way

Three deliberate choices, listed so you don't "fix" this by accident:

1. **No `sshpass` dependency.** Avoids extra binary install + maintenance, and
   most modern sshd configs ship with `PasswordAuthentication no` anyway.
2. **Parallel apply incompatible with TTY prompts.** `fleet-apply` runs N hosts
   concurrently; an interactive password prompt would deadlock the orchestrator.
3. **Security posture.** SSH password auth has known weaknesses (online
   brute-force surface). The repo philosophy nudges users toward key-based.

## Fix (per-host)

Recommended:

```sh
ssh-copy-id <host>                              # push your pubkey
ssh -o BatchMode=yes <host> true && echo OK     # verify key auth works non-interactively
just fleet-status                                # confirm host now classifies correctly
```

### Gotcha: `ssh-copy-id` succeeds but ssh STILL asks for password

Seen on `zyc_friend` (IDC server) 2026-05-08. `ssh-copy-id` reports
`Number of key(s) added: 1` and the `~/.ssh/authorized_keys` entry IS on the
remote, but next login still prompts. `ssh -v` reveals:

```
Authentications that can continue: gssapi-keyex,gssapi-with-mic,keyboard-interactive
```

Note `publickey` is **absent**. The remote sshd has `PubkeyAuthentication no`
(common in corporate / IDC security baselines). The key was deposited but the
server refuses to consider it. Two consequences:

1. `ssh-copy-id` itself runs over `keyboard-interactive` (PAM), not over
   key auth — it succeeds at the file-write step but proves nothing about
   future logins.
2. Even adding `sshpass` support to fleet-apply (the deferred TODO) wouldn't
   trivially work — `sshpass` defaults to the `password` method, but PAM-only
   sshds need `-o PreferredAuthentications=keyboard-interactive,password`.

Fix: ask the remote admin to enable `PubkeyAuthentication yes` in
`/etc/ssh/sshd_config` (+ `systemctl reload sshd`). If they refuse, drop the
host from the fleet inventory and apply manually.

Verify pubkey auth is allowed before troubleshooting your own keys:

```sh
ssh -v <host> true 2>&1 | grep "Authentications that can continue"
# Must include `publickey` for fleet-apply to ever work.
```

If the remote forbids key auth (rare; usually a misconfigured `sshd_config`
with `PubkeyAuthentication no`), edit the remote sshd or remove the host from
the fleet inventory and apply manually:

```sh
ssh <host>
# inside the remote shell:
chezmoi update --apply
```

## Detection

Quick triage when a host shows `unreachable`:

```sh
# 1. Does manual SSH work?
ssh <host> true && echo "ssh works"

# 2. Does it work non-interactively (the mode fleet uses)?
ssh -o BatchMode=yes -o ConnectTimeout=5 <host> true
# If this prompts or errors → no usable key auth → fleet can't reach it
```

If step 1 prompts for a password but step 2 errors with `Permission denied
(publickey,password)`, you've hit this pitfall.

## Related

- `dot_config/fleet/create_private_machines.toml.tmpl` — schema doc (consider
  amending the `password_source` comment to clarify it's sudo-only)
- `docs/this_repo/fleet-apply.md` → "Readiness probe" — describes the
  `_classify_readiness` state vocabulary
- `docs/this_repo/sudo-session.md` → "Non-interactive password injection" — the
  consumer side of `password_source` / `CHEZMOI_SUDO_PASSWORD_FILE`
- `pitfalls/sudo-shared-setsid-macos.md` — adjacent sudo-helper trap
