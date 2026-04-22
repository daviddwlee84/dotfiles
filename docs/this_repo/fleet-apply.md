# Fleet apply — multi-host `chezmoi update` orchestrator

> **TL;DR** — `just fleet-apply` runs `chezmoi update --init` on every host
> listed in `~/.config/fleet/machines.toml`, in parallel, with optional sudo
> password injection sourced from plaintext / interactive prompt / Bitwarden
> CLI. Per-host logs land under `logs/fleet-apply/<UTC-timestamp>/<host>.log`
> and the process exits with the number of failed hosts (capped at 125).

Implementation: [`scripts/fleet_apply.py`](../../scripts/fleet_apply.py)
(uv inline-script: `asyncssh` + `tyro` + `rich`).

## When to use

You edited dotfiles on the workstation, pushed to the repo's git remote, and
now want every laptop / VM / lab box to pick up the change without sshing into
each one and typing the sudo password by hand.

## When NOT to use

- This tool **does not** push the dotfiles repo itself — every remote runs
  `chezmoi update`, which does `git pull` on the remote's source dir. Your
  changes must already be reachable by the remotes (push to GitHub / your
  internal git host first).
- It does not run `just upgrade-*` on remotes. That's a separate concern; this
  tool stays scoped to chezmoi apply.
- It does not provision new hosts. Each remote must already have `chezmoi`
  installed and `chezmoi init` completed at least once.

## Inventory file

Path: `~/.config/fleet/machines.toml`. Seeded **once** by chezmoi from
[`dot_config/fleet/create_private_machines.toml.tmpl`](../../dot_config/fleet/create_private_machines.toml.tmpl).
The `create_private_` prefix means:

- `create_` → chezmoi seeds the file on first apply, then never touches it
  again. Your edits survive every `chezmoi apply`.
- `private_` → file mode 0600. Safe to keep plaintext sudo passwords here.
- To reset the seed: `rm ~/.config/fleet/machines.toml && chezmoi apply`.

### Schema

```toml
[defaults]                    # merged into every host (host keys override)
chezmoi_path    = "chezmoi"   # PATH binary; e.g. "~/.local/bin/chezmoi" if no-root
connect_timeout = 15
command_timeout = 1800

[[hosts]]
name            = "lab-box"   # required, unique display name
ssh_alias       = "lab-box"   # preferred: matches `Host lab-box` in ~/.ssh/config
# OR explicit connection (used when no ssh_alias):
hostname        = "203.0.113.42"
user            = "dwlee"
port            = 22
identity_file   = "~/.ssh/id_ed25519"

no_root_machine = false       # MUST mirror the chezmoi `noRoot=` value used at
                              # `chezmoi init` time on that remote (see below)
chezmoi_path    = "chezmoi"   # override defaults per-host
extra_env       = { FOO = "bar" }   # extra env vars for the remote chezmoi run

password_source = { type = "...", ... }   # see "Password sources" below
```

### Password sources

| `type` | Extra keys | Behaviour |
|---|---|---|
| `none` (default) | — | No password injected. Suitable for `no_root_machine = true` hosts. |
| `plain` | `value = "..."` | Read straight from TOML. Relies on file mode 0600. |
| `prompt` | — | `getpass()` once at startup, never persisted to disk. |
| `bitwarden` | `item = "ssh-host-sudo"` | `bw get password <item>` at startup. Requires `bw unlock` + `BW_SESSION` exported. |

### `no_root_machine` semantics

This flag **describes** the remote, it does not change it. Each remote was
configured at `chezmoi init` time with a `noRoot` boolean (see
[`.chezmoi.toml.tmpl:48`](../../.chezmoi.toml.tmpl)) that's now baked into
`~/.config/chezmoi/chezmoi.toml` on that machine.

- Set `no_root_machine = true` for hosts where the remote's `noRoot = true` —
  fleet_apply skips sudo entirely (no password file written, run-scripts'
  `sudo_session_init` returns "non-interactive" branch and skips sudo work).
- Set `no_root_machine = false` for hosts where the remote's `noRoot = false`
## How sudo password reaches the remote

`scripts/fleet_apply.py` does **not** echo the password into the command line.
The remote command (assembled by `build_remote_command()`) reads stdin into
`~/.cache/chezmoi-fleet/sudo.pass` (mode 0600, `umask 077`), exports
`CHEZMOI_SUDO_PASSWORD_FILE=$PWD/.cache/chezmoi-fleet/sudo.pass`, runs
`chezmoi update`, then `trap … EXIT` removes the file (even on crash).

On the remote, `scripts/lib/sudo_shared.sh::sudo_session_init` was extended
with a non-interactive injection path: when `CHEZMOI_SUDO_PASSWORD_FILE`
points to a readable file, the password is validated with `sudo -S -v`, then
adopted into the shared state dir (`$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/`)
exactly the same way an interactive prompt would be — including the watchdog
that holds the sudo timestamp warm and writes `ansible-become.yml` for
ansible roles. **Subsequent run-scripts inside the same `chezmoi update` see
the cached state and never re-prompt.**

Pass file lifecycle:
- `~/.cache/chezmoi-fleet/sudo.pass` is the orchestrator's drop-off; removed
  by the SSH command's `trap` once chezmoi exits.
- `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/sudo.pass` is the shared state dir
  managed by `sudo_shared.sh`; cleaned up by the existing watchdog when the
  ancestor `chezmoi` PID exits.

## Connection: ssh_config alias vs explicit

`asyncssh.connect(host=...)` reads `~/.ssh/config` like the OpenSSH client.
Prefer `ssh_alias`:

```
# ~/.ssh/config
Host lab-box
    HostName 10.0.0.42
    User dwlee
    ProxyJump bastion
    IdentityAgent ~/.1password/agent.sock     # 1Password SSH agent
```

```toml
# machines.toml
[[hosts]]
name      = "lab-box"
ssh_alias = "lab-box"          # ← inherits everything above, including ProxyJump
```

If a host has no ssh_config entry, fall back to explicit
`hostname` / `user` / `port` / `identity_file`.

## Commands

```bash
just fleet-apply                                # parallel, all hosts, update --init
just fleet-apply-dry-run                        # `chezmoi diff` instead of update
just fleet-apply-one lab-box                    # single host, --serial mode
just fleet-apply --hosts lab-box,vps-tokyo      # subset
just fleet-apply --exclude throwaway-vm         # all except
just fleet-apply --max-parallel 3               # throttle SSH fan-out
just fleet-apply --no-init                      # `chezmoi apply` (skip update)
just fleet-apply --serial                       # one at a time, no live table
just fleet-apply --command-timeout 600          # tighter timeout for warm fleets
just fleet-apply-kill                           # kill orphan chezmoi/ansible on every host
```

## Timeouts

| Flag | Default | Rationale |
|---|---|---|
| `--connect-timeout` | 30 s | SSH banner + auth handshake. Bump for high-latency or relay-heavy hosts. |
| `--command-timeout` | 7200 s (2 h) | Generous to cover first-run apply: Linuxbrew install (10–20 min) + 22 ansible roles + Brewfile cask downloads (GUI apps; can be 20+ min on slow links) + python_uv_tools / npm / cargo bootstrap. After your fleet is past first-run, drop to e.g. `--command-timeout 600` (10 min) — steady-state re-apply on a warm machine usually finishes in 1–5 min. |

If `--command-timeout` fires, the orchestrator sends SIGTERM via the SSH
channel **and** closes the channel (which delivers SIGHUP to the remote
shell, which the wrapper's trap propagates to chezmoi). The remote should
fully exit within seconds.

## Killing orphans

Local Ctrl+C, network drop, or any other premature disconnect is handled
two ways:

1. **In-band cleanup**: `build_remote_command()` wraps chezmoi in a shell
   wrapper with `trap '… pkill -TERM -P $_cz_pid …' INT TERM HUP`. asyncssh
   uses `request_pty='force'`, so the SSH channel close delivers SIGHUP to
   that wrapper shell on the remote — chezmoi (and any ansible-playbook
   children) get SIGTERM-ed and the wrapper proxies the exit code back.

2. **Out-of-band rescue**: if you killed `fleet_apply.py` so abruptly that
   even the in-band trap didn't fire (e.g. `kill -9` on the Python process,
   or your laptop slept), run:

   ```bash
   just fleet-apply-kill                       # all hosts
   just fleet-apply-kill --hosts lab-box       # specific host
   ```

   This connects to each host and runs `pkill -TERM -u "$(id -un)" -x
   chezmoi`, then `pkill -TERM -x ansible-playbook` and `ansible`, waits
   1 s, then SIGKILLs anything still alive. Output is one line per host
   showing exit status. No chezmoi command is sent, so this is safe to run
   any time the fleet looks "stuck".

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | All selected hosts finished `chezmoi update` with rc 0 |
| `N` (1–125) | `N` hosts failed (rc != 0, SSH error, timeout, or skipped due to missing sudo password) |
| 125 | More than 125 hosts failed (capped) |
| 2 | Config error (missing TOML, malformed schema) |

This makes the recipe usable from CI / cron loops without bespoke parsing.

## Logs

Per-host log file: `logs/fleet-apply/<UTC-timestamp>/<host>.log`. Each line is
prefixed `[out]` or `[err]`. The first two lines record the host metadata and
the **literal** remote command sent (which contains no password — only the
shell that pipes stdin into the pass file).

`logs/` is **not** in `.chezmoiignore.tmpl` because it lives in the source
repo only when you run `just fleet-apply` from inside the repo. Add it to
your local `.gitignore` if you don't already have one for build artifacts.

## Troubleshooting

- **`zsh:1: command not found: chezmoi` / rc=127** — non-interactive SSH
  shells don't source `~/.zshrc`, so `~/.local/bin` (or wherever your
  package manager put chezmoi) is not on PATH. The default
  `chezmoi_path = "auto"` already augments PATH with `~/.local/bin`,
  `~/bin`, `/opt/homebrew/bin`, `/home/linuxbrew/.linuxbrew/bin`,
  `/usr/local/bin`, `/snap/bin` before invoking chezmoi — covers ~all
  installs. If your binary lives elsewhere, pin it explicitly:
  ```toml
  [[hosts]]
  name         = "weird-box"
  chezmoi_path = "/opt/custom/bin/chezmoi"
  ```
  Run `ssh <host> command -v chezmoi` (interactive) vs
  `ssh <host> 'command -v chezmoi'` (non-interactive) to see the gap.
- **`bw get password` fails** — run `bw unlock`, then `export BW_SESSION=...`.
- **`asyncssh.PermissionDenied`** — the alias resolves but auth failed.
  Test with `ssh <alias> echo ok` first; if you use the 1Password agent,
  ensure `IdentityAgent` is set in ssh_config and the agent is unlocked.
- **First-time host rejected with "Host key verification failed"** —
  fleet_apply uses `known_hosts=None` (= skip its own check, defer to your
  `~/.ssh/known_hosts`). Run `ssh <alias>` manually once to TOFU the key.
- **Remote chezmoi prompts for the noRoot question and stalls** — the host
  was never `chezmoi init`'d. SSH in and run `chezmoi init` once interactively.
- **Sudo phase fails immediately on a no_root_machine=false host** — the
  password the orchestrator resolved was wrong. The remote
  `sudo_shared.sh` rejects it with an explicit message in stderr (caught in
  the per-host log).
- **Host hangs forever during `chezmoi diff` / `update`** — usually chezmoi
  spawned its configured pager (`bat`, `delta`, `less`) which blocked
  waiting for terminal input. fleet_apply already passes `--no-pager` to
  every chezmoi invocation, but if you've added a custom subcommand /
  hookScript that bypasses chezmoi's pager handling, kill the orphan with
  `just fleet-apply-kill --hosts <host>` and check that subcommand for
  pager / `read` calls.
- **Run looks dead after Ctrl+C** — when you Ctrl+C `fleet_apply.py`
  asyncio cancels each task, which calls `proc.terminate()` and closes the
  SSH connection. The remote wrapper's trap catches the resulting SIGHUP
  and SIGTERMs the chezmoi tree. If anything still survives, run
  `just fleet-apply-kill` to broadcast `pkill -TERM` (then SIGKILL) to
  every host's `chezmoi` / `ansible-playbook` / `ansible` processes.

## Related docs

- [`docs/this_repo/sudo-session.md`](sudo-session.md) — full `sudo_shared.sh`
  helper API, including the `CHEZMOI_SUDO_PASSWORD_FILE` env-injection path
  this tool relies on.
- [`docs/this_repo/upgrades.md`](upgrades.md) — for upgrading tools on a
  remote, ssh in and run `just upgrade-all` there. fleet_apply intentionally
  stays scoped to chezmoi apply only.
- [`AGENTS.md`](../../AGENTS.md) — repo invariants, including why
  `scripts/**` is in `.chezmoiignore.tmpl` (so `fleet_apply.py` is never
  deployed to `$HOME` and only ever runs from the repo).
