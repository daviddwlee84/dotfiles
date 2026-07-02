# `fleet-status` reports `unreachable` even though `ssh <host>` works interactively

**Status**: conditionally fixed 2026-07-02 (opt-in) — `fleet` now supports an `ssh_login_password_source`
field for hosts where SSH key auth is impossible. See
[`docs/this_repo/fleet-apply.md` § SSH login password sources](../docs/this_repo/fleet-apply.md#ssh-login-password-sources-opt-in-fallback)
and `backlog/fleet-ssh-password-login.md`. The rest of this page still applies to hosts that haven't
opted in (the default), and the root-cause explanation below is corrected to match the actual code.

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

**SSH login itself is a single in-process `asyncssh.connect()` call** (via the
shared `_connect_kwargs()`/`connect_host()` helpers in `scripts/fleet/apply.py`)
— not a `subprocess` shell-out to the OpenSSH client, and no `sshpass`
involvement. (An earlier version of this doc claimed a `subprocess` →
`ssh -o BatchMode=yes` shell-out; that was inaccurate — asyncssh is a
pure-Python/asyncio SSH implementation, no `ssh` binary or subprocess is ever
spawned.) When key auth fails, asyncssh raises `asyncssh.PermissionDenied`,
and the host is classified `unreachable` by `_classify_readiness()`.

So the password schema works at two completely different stages:

| Stage | Auth mechanism | Reads `password_source`? |
|---|---|---|
| SSH login (transport) | key / agent by default; opt-in password/PAM fallback via `ssh_login_password_source` | ❌ NO (reads the separate `ssh_login_password_source` field instead) |
| Remote `sudo` (after login) | `CHEZMOI_SUDO_PASSWORD_FILE` from `password_source` | ✅ YES |

The schema doc (`dot_config/fleet/create_private_machines.toml.tmpl` lines
49–54) labels `type = "plain"` as "last resort — relies on file mode 0600",
which reads as if it covers everything. It doesn't say *what* it covers.

## Why it's designed this way

Three deliberate choices behind the *default* (key/agent-only) behaviour —
still true, and still why `ssh_login_password_source` is opt-in rather than
the default:

1. **No `sshpass`/`expect` dependency.** The opt-in fallback (below) uses
   asyncssh's own native `password=`/`preferred_auth=` kwargs — no extra
   binary was added. Most modern sshd configs ship with
   `PasswordAuthentication no` anyway, so most hosts never need this.
2. **Parallel apply incompatible with TTY prompts.** `fleet-apply` runs N hosts
   concurrently; the fallback's `prompt`-type password source is resolved
   synchronously for all hosts *before* the parallel connection phase starts
   (same as the existing sudo `resolve_passwords()`), so it never deadlocks.
3. **Security posture.** SSH password auth has known weaknesses (online
   brute-force surface). The repo philosophy nudges users toward key-based —
   hence opt-in, not a silent global fallback.

## Fix (per-host)

**Preferred, if the remote allows it**: fix key auth so you never need a
password at all —

```sh
ssh-copy-id <host>                              # push your pubkey
ssh -o BatchMode=yes <host> true && echo OK     # verify key auth works non-interactively
just fleet-status                                # confirm host now classifies correctly
```

**If the remote admin won't/can't enable pubkey auth** (e.g. a fixed corporate
IDC policy — see the `zyc_friend` gotcha below): set `ssh_login_password_source`
on that host's `[[hosts]]` entry (example 6 in
`dot_config/fleet/create_private_machines.toml.tmpl`) instead of dropping the
host from the fleet. `fleet` still tries key/agent auth first — the password
source only kicks in as a fallback after that's rejected.

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
2. A naive `sshpass` integration wouldn't have trivially worked here either —
   `sshpass` defaults to the `password` method, but PAM-only sshds need
   `-o PreferredAuthentications=keyboard-interactive,password`. This is
   exactly why the shipped fix uses `asyncssh`'s native
   `preferred_auth=("keyboard-interactive", "password")` kwarg instead of
   `sshpass`: asyncssh auto-answers a single-prompt keyboard-interactive
   challenge (like PAM's "Password:") using the same `password` value,
   handling both auth methods with one field. See
   `backlog/fleet-ssh-password-login.md` for the full options-considered
   writeup.

Fix: ask the remote admin to enable `PubkeyAuthentication yes` in
`/etc/ssh/sshd_config` (+ `systemctl reload sshd`) — still preferred where
possible. Otherwise, set `ssh_login_password_source` on the host (see "Fix
(per-host)" above) rather than dropping it from the fleet inventory.

Verify pubkey auth is allowed before troubleshooting your own keys:

```sh
ssh -v <host> true 2>&1 | grep "Authentications that can continue"
# `publickey` present → fix your keys / ssh-copy-id.
# `publickey` absent  → key auth is impossible here; set
#                        ssh_login_password_source instead (see "Fix" above).
```

If the remote forbids key auth (rare; usually a corporate/IDC `sshd_config`
with `PubkeyAuthentication no`), either ask the remote admin to change it, or
set `ssh_login_password_source` on that host (preferred over removing it from
the fleet inventory — see "Fix (per-host)" above) so `fleet` can still manage
it via its opt-in password/PAM fallback.

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
(publickey,password)`, you've hit this pitfall — set `ssh_login_password_source`
on the host (see "Fix (per-host)" above) rather than treating it as
unfixable.

## Related

- `dot_config/fleet/create_private_machines.toml.tmpl` — schema doc, example 6
  demonstrates `ssh_login_password_source`
- `docs/this_repo/fleet-apply.md` → "Readiness probe" — describes the
  `_classify_readiness` state vocabulary; "SSH login password sources" and
  "How the SSH login password reaches asyncssh" — the fix itself
- `docs/this_repo/sudo-session.md` → "Non-interactive password injection" — the
  consumer side of `password_source` / `CHEZMOI_SUDO_PASSWORD_FILE` (still
  sudo-only, unaffected by this fix)
- `backlog/fleet-ssh-password-login.md` — options considered (asyncssh-native
  vs `sshpass` vs `expect`) and why asyncssh-native won
- `pitfalls/sudo-shared-setsid-macos.md` — adjacent sudo-helper trap
