# Fleet apply — multi-host `chezmoi update` orchestrator

> **TL;DR** — `just fleet-apply` runs `chezmoi update --init` on every host
> listed in `~/.config/fleet/machines.toml`, in parallel, with optional sudo
> password injection sourced from plaintext / interactive prompt / Bitwarden
> CLI. Per-host logs land under `logs/fleet-apply/<UTC-timestamp>/<host>.log`
> and the process exits with the number of failed hosts (capped at 125).

Implementation: [`scripts/fleet_apply.py`](../../scripts/fleet_apply.py)
(uv inline-script: `asyncssh` + `tyro` + `rich`).

See also: [fleet-apply-vs-fabric.md](fleet-apply-vs-fabric.md) for an
archaeological comparison against the author's 2018-era Fabric `fabfile.py`
on RaspPi-Cluster — same problem shape, ~7 years of operational lessons
encoded into the current implementation.

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
local           = false       # set true to run chezmoi locally (no SSH); see
                              # "Local host execution" section below
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

## Local host execution (`local = true`)

To include the orchestrator machine itself in a fleet apply, add a host
with `local = true`:

```toml
[[hosts]]
name            = "self"
local           = true
no_root_machine = true   # set false if your local apply needs sudo
```

Local hosts skip asyncssh entirely — chezmoi runs as a direct
subprocess (`asyncio.create_subprocess_exec`) inheriting the
orchestrator's PATH, sudoers state, and tty. Sudo password injection
is not used; if chezmoi needs root it'll prompt on the parent terminal.
The `kill-orphans` subcommand also skips local hosts (killing local
chezmoi processes from the same shell session would kill `fleet_apply`
itself). All other features — log files, live table, `--force`,
`--keep-going`, `--command-timeout`, parallelism — work identically.

`ssh_alias`, `hostname`, `user`, `port`, `identity_file` are ignored
when `local = true`. `chezmoi_path = "auto"` still works (subprocess
inherits the calling shell's PATH, which is where the orchestrator
itself found `chezmoi`).

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

### Vibe-loop recipes (fast iteration)

```bash
just fleet-diff lab-box                         # `chezmoi diff` on ONE host, serial output
just fleet-apply-file .zshrc                    # apply ONE file across the fleet, skip ansible
just fleet-apply-file .config/zsh/aliases.zsh --hosts lab-box
just fleet-apply-branch feature/new-tmux        # pin remotes to a branch (ff-only)
just fleet-apply-branch-force feature/new-tmux  # … allow `git reset --hard` (after rebase)
```

`fleet-apply-file PATH` is the headline vibe-loop command:

- Skips `chezmoi update` (and thus the slow `run_*` scripts: ansible, Brewfile, Linuxbrew refresh).
- Prepends `git -C $(chezmoi source-path) pull --ff-only` so the remote checkout has your latest commit before `chezmoi apply --exclude=scripts <PATH>` re-renders just that one target.
- PATH is a chezmoi *target* path (relative to `$HOME`), e.g. `.zshrc`, `.config/tmux/tmux.conf`, `.gitconfig`. NOT a source path like `dot_zshrc`.
- Round-trip on a warm fleet is typically ~5-15 seconds per host vs 5-30 minutes for a full `fleet-apply`.
- You still need to `git push` first — the remote runs `git pull` on its checkout. Local hosts (`local = true`) skip the pull because the source IS your editor's working tree.
- Drift / `--force` semantics are unchanged: pass `--force` if you've also edited the file by hand on the remote and want to overwrite.

`fleet-apply-branch BRANCH` lets you iterate on a feature branch without polluting `main`:

- Each remote runs `git fetch origin BRANCH && git checkout -B BRANCH origin/BRANCH && git merge --ff-only origin/BRANCH` before `chezmoi apply`.
- Mode is forced to `apply` (since `chezmoi update` would re-pull `main` and undo the checkout).
- Default merge is `--ff-only`: fails loud if the remote checkout has divergence. Use `fleet-apply-branch-force` (which adds `--force-checkout`) to swap in `git reset --hard origin/BRANCH` — necessary after you've force-pushed a rebased topic branch.
- Local hosts ignore `--branch` entirely: their source dir is your working tree, switching it under your editor would be hostile. The skip is logged.
- Compose with `--apply-only-path` for the fastest possible loop: `just fleet-apply --branch tmp/test --apply-only-path .config/foo/bar.toml --hosts lab-box`.


## Conflict handling: `--force` vs `--keep-going`

When a remote file has drifted from what chezmoi last wrote (someone
edited it directly on the host), chezmoi normally prompts on `/dev/tty`
to ask whether to overwrite. fleet_apply runs without a PTY, so that
prompt dies with `chezmoi: <file>: could not open a new TTY: open
/dev/tty: no such device or address`. Two flags control the response:

| Flag | Default | Effect on the conflicting file | Effect on the rest of the apply |
|---|---|---|---|
| `--keep-going` / `--no-keep-going` | **on** | Left **unchanged** (no override) | Continues — other files still apply |
| `--force` / `--no-force` | **off** | **Overwritten** with template render | Same |

Default combination (`--keep-going`, no `--force`) = **non-destructive**:
all clean files apply, drifted files are skipped. fleet_apply parses the
chezmoi stderr; if the host's *only* failure is "could not open a new TTY"
on one or more drifted targets, it classifies the host as **`drift`**
(yellow `⚠`) instead of **`failed`** (red `✗`). The summary lists the
drifted files per host so you know exactly what needs attention:

```
Summary: 5 hosts, 3 ok, 1 failed, 1 drift, 0 skipped
  ✗ david_ubuntu  rc=1  log=…/david_ubuntu.log     # real failure
  ⚠ hanru_mac     drift in: .config/foo.toml       # only a drift skip
                  log=…/hanru_mac.log
                  (resolve: --force, or sync edits back to source)
```

Drift hosts do **not** count toward the process exit code — only `failed`
hosts do. This is intentional: drift is a "do something later" signal, not
a CI failure. If a host has BOTH a drift skip AND an unrelated error
(ansible task, network timeout, etc.) it will be classified as `failed`,
not `drift`, so real errors are never silently downgraded.

To resolve a drift, either:

- Migrate the drift into a per-machine override file (e.g. `~/.gitconfig.local`,
  see below) and re-run.
- Or run `just fleet-apply --force` once to let the canonical template win
  (also accepts `--hosts <name>` to scope it).
- Or, for a single file you've already decided about, ssh in and run
  `chezmoi apply --force <relpath>` directly — fastest fix when the
  template is right but the target is stale.

## Per-machine git overrides (`~/.gitconfig.local`)

Common drift on `.gitconfig` is host-specific git config that legitimately
belongs to that one machine — `[safe] directory = /mnt/NAS/...` (host-mounted
NAS), `[credential "https://gitlab.com"]` (glab CLI helper), `[http] proxy = ...`
(corporate proxy), etc. Putting these in the chezmoi-managed
`dot_gitconfig.tmpl` is wrong (they don't apply to other hosts);
hand-editing them onto each remote also fails because every fleet apply
then trips the "drifted from template" prompt.

`dot_gitconfig.tmpl` therefore ends with:

```gitconfig
[include]
    path = ~/.gitconfig.local
```

`include.path` is silently skipped by git when the file doesn't exist
(no error), so machines without overrides are unaffected. `~/.gitconfig.local`
is git-ignored by chezmoi via `.chezmoiignore` — chezmoi will never seed,
overwrite, or diff it. Same self-managed pattern as `~/.zshrc.adhoc`
for shell customisations.

To migrate per-host lines that already drifted on a remote:

```bash
ssh <host> 'chezmoi --no-pager diff .gitconfig'   # see what diverged
ssh <host> bash -s <<'EOF'
  # Move the host-specific block out of the managed file:
  # (manually copy the [safe] / [credential] / [http] sections from
  # ~/.gitconfig into ~/.gitconfig.local with your editor of choice)
  ${EDITOR:-vi} ~/.gitconfig.local
  ${EDITOR:-vi} ~/.gitconfig         # delete the migrated lines
EOF
just fleet-apply-one <host>                       # should now be clean
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

## Killing orphans, checking status, re-attaching

Local Ctrl+C, network drop, laptop sleep, or any other premature
disconnect is handled three ways:

1. **In-band cleanup**: `build_remote_command()` wraps chezmoi in a shell
   wrapper with `trap '… pkill -TERM -P $_cz_pid …' INT TERM HUP`. asyncssh
   uses `request_pty='force'`, so the SSH channel close delivers SIGHUP to
   that wrapper shell on the remote — chezmoi (and any ansible-playbook
   children) get SIGTERM-ed and the wrapper proxies the exit code back.
   In practice this fires whenever asyncssh actually closes the channel
   (which is most cases, including normal SIGINT on the controller).

2. **Out-of-band rescue**: if even the in-band trap didn't fire (e.g.
   `kill -9` on `fleet_apply.py`, or asyncssh closed the channel
   "cleanly" without a HUP delivery), the remote chezmoi/ansible may
   still be running:

   ```bash
   just fleet-apply-kill                       # all hosts
   just fleet-apply-kill --hosts lab-box       # specific host
   ```

   This connects to each host and runs `pkill -TERM -u "$(id -un)" -x
   chezmoi`, then `pkill -TERM -x ansible-playbook` and `ansible`, waits
   1 s, then SIGKILLs anything still alive. No chezmoi command is sent,
   so this is safe to run any time the fleet looks "stuck".

3. **Status probe + live tail re-attach** (added after observing that
   asyncssh + a slow laptop-side kill sometimes leaves remote work
   running for many minutes silently):

   ```bash
   just fleet-apply-status                     # which hosts are still busy?
   just fleet-apply-status --hosts ts_nas      # one host
   just fleet-apply-watch                      # poll every 10s until idle
   just fleet-apply-tail jingle207             # follow latest run on this host
   just fleet-apply-tail jingle207:20260422T140446Z
                                               # pin a specific run id
   ```

   Each remote run tees chezmoi's combined stdout/stderr to
   `~/.cache/chezmoi-fleet/logs/<run_id>.log` and drops a sentinel
   `<run_id>.exit` file containing the final exit code when the run
   finishes. `--status` reads both: it shows `running` (live PIDs +
   their numbers), `finished` (with the exit code), or `idle` per host,
   plus the last 5 lines of the latest log inline for quick context.
   `--tail` does a `tail -F` on the log over a fresh SSH session and
   exits cleanly when the sentinel appears (or you Ctrl+C the viewer
   — the remote run keeps going).

   `--watch N` (or `just fleet-apply-watch` which presets N=10) repeats
   `--status` every N seconds until every host reports finished/idle,
   then exits 0. Use this as a passive "wait for the fleet to settle"
   cursor after killing the controller — no need to keep pressing
   ↑↩ to re-poll. Subsequent polls suppress the per-host log tail to
   keep output compact.

   **Self / `local = true` hosts** are first-class here: their logs
   land in `~/.cache/chezmoi-fleet/logs/` on the orchestrator (same
   dir, no SSH round-trip). `--status` and `--tail self` work
   identically to SSH hosts. The PID filter excludes the probe's own
   process and parent so a `--status` invocation doesn't see itself.

   Both probes are read-only: they never send a chezmoi command and
   never kill anything. Combine with `fleet-apply-kill` if you decide
   the remote work should stop.

### Log retention

Each per-host log dir keeps the **10 most recent** runs (`.log` +
`.exit` pair); older pairs are deleted at the end of the next run.
Override with `--keep-logs N` (`N=0` disables GC entirely if you want
to accumulate forever — you'll need to `rm -rf ~/.cache/chezmoi-fleet/
logs` periodically yourself). GC happens AFTER the sentinel is
written, so the just-finished run is always inside the keep window.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | All selected hosts finished `chezmoi update` with rc 0, or only had recoverable drift skips (state = `drift`) |
| `N` (1–125) | `N` hosts genuinely failed (rc != 0 with errors *other than* drift skips, SSH error, timeout, or skipped due to missing sudo password) |
| 125 | More than 125 hosts failed (capped) |
| 2 | Config error (missing TOML, malformed schema) |

`drift` hosts intentionally do NOT count as failures — see "Conflict
handling" above. They appear in the summary as `⚠` so a human notices, but
CI / cron loops keep passing as long as no real errors occur.

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
- **`chezmoi: <file>: could not open a new TTY: open /dev/tty: no such device or address`** —
  the file drifted on the remote and chezmoi tried to prompt. With the
  default `--keep-going`, the file is left untouched and the rest of
  the apply continues (host still reports rc!=0 so drift is visible).
  See [Conflict handling](#conflict-handling---force-vs---keep-going)
  for the resolution flow; for `.gitconfig` specifically, migrate the
  per-host lines to [`~/.gitconfig.local`](#per-machine-git-overrides-gitconfiglocal)
  instead of using `--force`.
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
