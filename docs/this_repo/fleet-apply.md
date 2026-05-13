# Fleet apply — multi-host `chezmoi update` orchestrator

> **TL;DR** — `just fleet-apply` runs `chezmoi update --init` on every host
> listed in `~/.config/fleet/machines.toml`, in parallel, with optional sudo
> password injection sourced from plaintext / interactive prompt / Bitwarden
> CLI. Per-host logs land under `logs/fleet-apply/<UTC-timestamp>/<host>.log`
> and the process exits with the number of failed hosts (capped at 125).
>
> **Before applying, run [`just fleet-status`](#readiness-probe-just-fleet-status)** — a read-only pre-flight probe that predicts what `fleet-apply` would do per host (up-to-date / behind / drift / busy / toml-mismatch / not-init / unreachable / ...).

Implementation: [`scripts/fleet/apply.py`](../../scripts/fleet/apply.py)
(uv inline-script: `asyncssh` + `tyro` + `rich`).

See also: [fleet-apply-vs-fabric.md](fleet-apply-vs-fabric.md) for an
archaeological comparison against the author's 2018-era Fabric `fabfile.py`
on RaspPi-Cluster — same problem shape, ~7 years of operational lessons
encoded into the current implementation.

## The fleet-* command family at a glance

The fleet- recipes split into **three layers** of concern. Pick the right one based on what you want to do:

| Recipe | What it does | Side effects | When to use |
|---|---|---|---|
| `just fleet-edit` | Open `~/.config/fleet/machines.toml` in `$EDITOR` (seeds an empty template on first run) | Edits inventory file only | First-time setup, adding/removing hosts |
| `just fleet-status` | **Pre-flight readiness probe** — predicts what `fleet-apply` would do per host | None (read-only, ~1.5s/host) | **Before** `fleet-apply`, to triage which hosts need attention |
| `just fleet-status-quick` | Same as `fleet-status` but skips remote `git fetch` (~0.5s/host) | None | Offline / quick re-check |
| `just fleet-apply-dry-run` | Run `chezmoi diff` on every host (full template render comparison) | Reads remote source dir; no writes | Detailed file-by-file preview after `fleet-status` flagged something |
| `just fleet-diff HOST` | `chezmoi diff` on ONE host, serial output | None | Inspecting exactly what one host would change |
| `just fleet-apply` | `chezmoi update --init` on every host (= `git pull` + re-render `chezmoi.toml` + `apply` + run_* scripts) | **Mutates remotes** | The actual deploy |
| `just fleet-apply-file PATH` | `chezmoi apply --exclude=scripts <PATH>` on every host (skips ansible / Brewfile) | Mutates only that one target | Vibe loop — fast feedback for one dotfile |
| `just fleet-apply-branch BRANCH` | Pin remotes to a feature branch before applying | Mutates remotes + checks out branch on remote source dir | Iterating on a topic branch across the fleet |
| `just fleet-apply-one HOST` | Apply to a single host in `--serial` mode (debug-friendly output) | Mutates that host | Targeted apply / debugging |
| `just fleet-apply-status` | **Process-liveness probe** — is a chezmoi/ansible run still going on each host? | None (read-only) | After Ctrl+C'ing controller, to see which remotes are still busy |
| `just fleet-apply-watch` | Same as `fleet-apply-status` but polls every 10s until everyone idle | None | Passive "wait for fleet to settle" cursor |
| `just fleet-apply-tail HOST` | Live-tail the latest fleet-apply log on `HOST` over a fresh SSH session | None | Re-attach to a still-running run after Ctrl+C |
| `just fleet-apply-compact` | Post-mortem summary across the fleet (final task, runtime, slow tasks, exit code) | None (reads remote logs) | After a finished run, when per-host `--tail` is too noisy |
| `just fleet-apply-kill` | `pkill -TERM` then `-KILL` chezmoi/ansible on every host | **Kills processes** | Cleanup after Ctrl+C left orphans |

> **Common naming confusion**: `fleet-status` ≠ `fleet-apply-status`. The first is a pre-apply readiness probe ("would `fleet-apply` succeed right now?"), the second is a process-liveness probe ("is a `fleet-apply` still running?"). They answer different questions and are usually used in different phases of your workflow.

### Typical workflows

```bash
# Daily: push to repo, then deploy.
git push
just fleet-status              # pre-flight check — anything need attention?
just fleet-apply               # actual deploy

# Vibe loop: edit one file, push, fast-apply across fleet.
git add .config/zsh/aliases.zsh && git commit -m "..." && git push
just fleet-apply-file .config/zsh/aliases.zsh

# After Ctrl+C'ing a long fleet-apply: where am I?
just fleet-apply-status        # which hosts still running?
just fleet-apply-watch         # wait until everyone idle
just fleet-apply-tail lab-box  # re-attach to one host's log
just fleet-apply-kill          # nuke leftover orphans

# After fleet-apply finished, want a summary:
just fleet-apply-compact
```

## Umbrella `fleet` binary

`dot_dotfiles/bin/executable_fleet` (deployed as `~/.dotfiles/bin/fleet`) is a
thin umbrella that exposes the same operations as the `just fleet-*` recipes
plus the two new read-only probes `fleet tmux` / `fleet info`. The advantage
over `just`: it works from any cwd, not just inside the chezmoi source tree.

| Umbrella subcommand | Equivalent `just` recipe |
|---|---|
| `fleet apply [...]` | `just fleet-apply` (and `fleet-apply-dry-run`, `fleet-apply-one`, `fleet-apply-file`, `fleet-apply-branch[-force]`) |
| `fleet status` | `just fleet-status` (readiness probe) |
| `fleet status --quick` | `just fleet-status-quick` |
| `fleet status --live` | `just fleet-apply-status` (process-liveness probe) |
| `fleet status --live --watch 10` | `just fleet-apply-watch` |
| `fleet diff HOST` | `just fleet-diff HOST` |
| `fleet tail HOST[:RUN_ID]` | `just fleet-apply-tail HOST` |
| `fleet kill` | `just fleet-apply-kill` |
| `fleet compact` | `just fleet-apply-compact` |
| `fleet edit` | `just fleet-edit` |
| `fleet tmux [...]` | (new) — see below |
| `fleet info [...]` | (new) — see below |
| `fleet pueue [...]` | (new) — cross-host pueue queue summary; `--ai` for cleanability + recovery hints via local `pqsum`. See [docs/tools/pueue.md](../tools/pueue.md). |
| `fleet exec [OPTS] -- CMD [...]` | (new) — cross-host argv-list command runner. Argv after `--` is safe by default (no shell expansion). `--shell bash\|zsh` for pipes/globs, `--login` for rc-loaded env, `--ai` for succeeded/differed/failed classification. See [docs/tools/fleet-exec.md](../tools/fleet-exec.md). |

The umbrella discovers the chezmoi source dir at runtime via `chezmoi
source-path` (falls back to `~/.local/share/chezmoi`) so it can `import` the
shared `scripts/fleet/` package and the legacy `scripts/fleet/apply.py`. From
inside the source tree, `just fleet *ARGS` invokes the same binary directly
(works before the first `chezmoi apply` lands `~/.dotfiles/bin/fleet`).

The existing `just fleet-*` recipes still call `./scripts/fleet/apply.py`
directly and are unaffected by the umbrella — they remain the muscle-memory
path for repo work. Pick whichever feels right: same code under the hood.

### Note on `fleet status` overload

`fleet status` has two modes. Default (`fleet status` / `--quick`) is the
**pre-flight readiness probe** — read-only, ~1.5s/host, predicts what
`fleet apply` would do. Adding `--live` flips it to the **process-liveness
probe** — does each host have a chezmoi/ansible run in flight right now?
The same overload is what `just fleet-status` vs `just fleet-apply-status`
expresses across two recipe names; the umbrella collapses it under one
subcommand because both flavors answer "what is the state of `apply` on
each host" — just at different time horizons (would-it-succeed vs
is-it-running).

## `fleet tmux` — cross-host tmux session summary

Quick "what's open where" across the fleet:

```bash
fleet tmux                                  # all hosts, default Rich table
fleet tmux --hosts self,ts_nas              # subset
fleet tmux --deep                           # include pane tails (slower)
fleet tmux --json                           # pipeable per-host JSON
```

Per-host execution strategy (`scripts/fleet/tmux.py`):

1. **Prefer**: invoke remote `~/.config/tmux/tmux-session-summary.py --json`
   (chezmoi deploys this on every managed host). Emits the `Session` / `Window`
   dataclasses as JSON — same schema `tsum` uses locally.
2. **Fallback**: run raw `tmux list-sessions -F ...` + `tmux list-windows -a -F ...`
   over SSH, then reconstruct the same JSON shape locally. Used when the `.py`
   isn't deployed (e.g. minimal host) or fails (e.g. version mismatch).
3. **None**: host has no tmux server / no tmux installed → row shows `0`
   sessions with `source=none`.
4. **N/A**: host unreachable → row renders `N/A` with the SSH error class,
   and the rest of the fleet keeps going.

Output columns: `HOST | SOURCE | SESSIONS | WINDOWS | ATTACHED | LAST_ATTACHED |
TOP_SESSION | ms`. `SOURCE` colors hint at the path used: green=py,
yellow=raw, dim=none, red=N/A.

**Not yet implemented**: `--with-summary` (LLM aggregate across hosts). Stub
that errors out with a hint to use `tsum` per-host or pipe `--json` to an
external tool.

**Cross-file invariant** (from `CLAUDE.md`): if you add a field to the
`Session` / `Window` dataclass in
`dot_config/tmux/executable_tmux-session-summary.py`, the raw-fallback parser
in `scripts/fleet/tmux.py:_parse_raw` MUST be updated to reconstruct it.

## `fleet info` — cross-host system status

Curated 8-column snapshot of every host: OS, CPU, RAM, disk, load, uptime,
docker containers, chezmoi drift.

```bash
fleet info                                   # default curated view, 8 modules
fleet info --hosts self                      # subset
fleet info --modules cpu,mem,disk            # only these
fleet info --full                            # all modules (+ gpu, network)
fleet info --ff                              # also dump fastfetch JSON per host
fleet info --json | jq .                     # pipeable
```

**Module catalog** (each gracefully degrades to `—` when the underlying tool
is missing — no GPU, no docker, no chezmoi on the host, etc.):

| Module | Linux source | macOS source |
|---|---|---|
| `os` | `lsb_release -ds` or `/etc/os-release` `PRETTY_NAME` | `sw_vers` |
| `cpu` | `/proc/cpuinfo` model name + `nproc` | `sysctl machdep.cpu.brand_string` + `hw.ncpu` |
| `mem` | `/proc/meminfo` (`MemTotal` - `MemAvailable`) | `sysctl hw.memsize` + `vm_stat` pages |
| `disk` | `df -k /` (root partition) | same (POSIX) |
| `load` | `/proc/loadavg` | `sysctl vm.loadavg` |
| `uptime` | `/proc/uptime` | `date +%s` - `sysctl kern.boottime` |
| `docker` | `docker ps -q \| wc -l` (running + total) | same |
| `chezmoi` | `chezmoi status` line count + commits behind | same |
| `gpu` (extra) | `nvidia-smi --query-gpu=name,memory.used,memory.total` | `system_profiler SPDisplaysDataType` chipset |
| `network` (extra) | `hostname -f` + `hostname -I` | `hostname` + `ipconfig getifaddr en0` |
| (with `--ff`) | `fastfetch --format json` (full dump appended per host) | same |

The probe is one bash blob per host: `MOD_<name>=<value>` (or `ERR:<msg>`)
lines parsed back into structured Python objects. Per-module failure inside a
host is isolated (row stays alive); per-host SSH failure renders the whole
row as `N/A`.

Exit code = number of hosts that failed end-to-end (capped at 125).

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

## Readiness probe (`just fleet-status`)

`fleet-apply` defaults to `chezmoi update --init`, which is **three things in
sequence** under the hood:

1. `git -C <source> pull` — bring in new template commits
2. `chezmoi init` — re-render `~/.config/chezmoi/chezmoi.toml` (re-evaluates `promptBoolOnce` / `promptStringOnce` calls; **NEW prompt keys without saved answers will fail non-interactively** with `chezmoi: ... could not open a new TTY`)
3. `chezmoi apply` — render templates, write targets, run `run_*` scripts (ansible, Brewfile, etc.)

The readiness probe inspects each host once over SSH and predicts what each of
those three sub-steps would do, **without changing anything**. Cheaper than
`fleet-apply-dry-run` (which runs full `chezmoi diff`) and more actionable
than `fleet-apply-status` (which only sees live processes, not pending
drift / missing init / new prompt keys).

```bash
just fleet-status                              # all hosts, with `git fetch`
just fleet-status --hosts lab-box,vps-tokyo    # subset
just fleet-status-quick                        # skip remote `git fetch` (faster, may show stale 'behind')
just fleet-status --readiness-json | jq .      # machine-readable
```

### State matrix

The probe classifies each host into exactly one primary state and zero or
more secondary notes (e.g. a `behind` host with drift will show
`behind: 3 commits, drift: 2 files` in the notes column).

| State | Symbol | Meaning | Recovery |
|---|---|---|---|
| `up-to-date` | ✓ green | Source dir at `origin/HEAD`, no drift, init done | Nothing to do |
| `ready-to-update` | ↻ blue | Source is behind origin → `fleet-apply` will pull + apply cleanly | `just fleet-apply --hosts HOST` |
| `behind` | → cyan | Same as `ready-to-update` but used when there are also other notes (drift / dirty co-existing) | `just fleet-apply --hosts HOST` |
| `drift` | ⚠ yellow | Remote target was hand-edited; would trigger "could not open a new TTY" prompt without `--force`. With default `--keep-going`, applies the rest of the fleet and skips this file | `just fleet-apply --hosts HOST --force` (overwrite) OR migrate to a `*.local` override |
| `dirty` | ⚠ yellow | Remote source dir has uncommitted changes (someone hand-edited the template on the remote) | ssh in & commit/stash before applying |
| `ahead` | ? magenta | Remote source dir has local commits not on origin — `git pull` would diverge | ssh in & `git push` or reset before applying |
| `busy` | ⏳ yellow | A `chezmoi update/apply/init` or `ansible-playbook` is already running, OR the chezmoi state lock is held | Wait, then re-probe; OR `just fleet-apply-status --hosts HOST` for live state |
| `init-in-progress` | ⏳ yellow | Source dir is missing/incomplete BUT a `chezmoi update/apply/init` PID is alive — typically mid-clone, or paused at an interactive prompt in another SSH session. Distinct from `no-source` (which is permanent until human intervention) | Wait for the in-flight init to finish, OR ssh in & check the other session |
| `toml-mismatch` | ! yellow bold | The local `.chezmoi.toml.tmpl` declares prompt keys (`promptBoolOnce` / `promptStringOnce` / etc.) that are missing from the remote's saved `~/.config/chezmoi/chezmoi.toml`. **This is the `david_ubuntu` failure mode** — `fleet-apply` will crash on this host with `chezmoi: ... could not open a new TTY` on `chezmoi init` | ssh in & re-run `chezmoi init` to answer the new prompts |
| `not-init` | ✗ red | `~/.config/chezmoi/chezmoi.toml` doesn't exist — host was never `chezmoi init`'d | ssh in & run `chezmoi init` interactively (one-off; needs TTY) |
| `no-source` | ✗ red | `chezmoi source-path` returns nothing or the path is not a git repo | ssh in & re-init (or fix custom `chezmoi.toml` `sourceDir =`) |
| `no-chezmoi` | ✗ red | `chezmoi` binary not found in augmented PATH | ssh in & install chezmoi (`curl https://chezmoi.io/get \| sh`) |
| `unreachable` | ✗ red | SSH connection failed (timeout, auth, host key, network) | check ssh_alias / network / sudo / 1Password agent |

### Output format

```
fleet-status — readiness probe across 6 host(s)
                                readiness probe
┏━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ host       ┃ state                  ┃ notes                                    ┃
┡━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┩
│ self       │ ✓ up-to-date           │                                          │
│ hanru_mac  │ ↻ ready-to-update      │ behind: 3 commits                        │
│ ts_nas     │ ⏳ busy                │ pids=12345                               │
│ jingle207  │ ⚠ drift                │ drift: .config/mise/config.toml          │
│ david_ub   │ ! toml-mismatch        │ missing prompt keys: installTunnelTools  │
│ idc-srv    │ ✗ unreachable          │ TimeoutError: 30s                        │
└────────────┴────────────────────────┴──────────────────────────────────────────┘

Hints:
  ✗ unreachable (1: idc-srv)
      → check ssh_alias / network / sudo / 1Password agent
  ! toml-mismatch (1: david_ub)
      → ssh in & re-run `chezmoi init` to answer the new prompts (their default values are usually fine)
  ⏳ busy (1: ts_nas)
      → wait for the running run, OR `just fleet-apply-status --hosts HOST` for live state
  ⚠ drift (1: jingle207)
      → `just fleet-apply --hosts HOST --force` (overwrite) OR migrate to a *.local override
  ↻ ready-to-update (1: hanru_mac)
      → `just fleet-apply --hosts HOST` (or whole fleet)

Summary: 2/6 hosts ready for `just fleet-apply`, 4 need attention
```

### Exit code

Always 0 (probe is informational). Use `--readiness-json` and parse for
fine-grained gating in CI:

```bash
# Pre-apply gate: refuse to apply if any host is unreachable.
if just fleet-status --readiness-json | jq -e 'any(.state == "unreachable")' >/dev/null; then
    echo "abort: at least one host unreachable"
    exit 1
fi
just fleet-apply
```

### How `toml-mismatch` works

The probe greps the **local** `.chezmoi.toml.tmpl` for `promptBool` /
`promptString` / `promptInt` / `promptChoice` (with or without `Once`)
calls and extracts the second positional argument (the prompt key name).
Then it compares against the set of top-level keys in the remote's saved
`~/.config/chezmoi/chezmoi.toml`. Any keys missing on the remote = the
remote will trigger an interactive prompt during `chezmoi update --init`,
which has no TTY → fails with the familiar `could not open a new TTY`.

False positives are unlikely — only newly-added prompt keys trigger this
state. False negatives are possible (e.g. if you wrap a prompt in a
template conditional that the remote's profile evaluates to false), but
those don't actually break `fleet-apply` either, so they're not a regression.

### Empty inventory UX

`just fleet-status` on a fresh box without `~/.config/fleet/machines.toml`
exits 0 with:

```
no fleet configured yet — Fleet config not found: ~/.config/fleet/machines.toml
hint: run `just fleet-edit` to add machines, then re-run `just fleet-status`.
```

`just fleet-edit` itself seeds an empty template (with `[defaults]` and a
commented-out `[[hosts]]` example) on first run, so you don't need to
remember the schema. `just fleet-apply` keeps its old strict behaviour
(exit 2 on missing config) — readiness is the only command that's
forgiving here.

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

`scripts/fleet/apply.py` does **not** echo the password into the command line.
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
just fleet-edit                                 # edit ~/.config/fleet/machines.toml ($EDITOR)
just fleet-status                               # readiness probe (use BEFORE apply — see § Readiness probe)
just fleet-status-quick                         # readiness probe, skip remote `git fetch`
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

### When a host hangs

`command_timeout` is the **outer** budget — it kills the entire chezmoi+ansible chain when blown. Ansible itself has **no per-task timeout**, so a stuck `npm install`, `apt update` retry loop, or `git clone` against a slow mirror will burn the whole 2-hour budget if you let it.

Typical hang symptoms:

- `--status` shows the host as `running pids=...` for tens of minutes
- `--tail HOST` log stops at a `[N] TASK · …` line and never advances
- Drilling into the remote: `ssh HOST pstree -p $PID` shows `python3 → /bin/sh -c "… npm install …"` (or apt / git / cargo equivalents) at the leaf

Recovery flow:

1. **Identify the stuck task** via `--tail HOST` (last visible TASK number) and `ssh HOST pstree` to confirm the leaf process.
2. **Kill the run**: `just fleet-apply-kill --hosts HOST` — broadcasts `pkill -TERM` then `-KILL` to chezmoi/ansible/orphans.
3. **Bound the next attempt**: re-run with `--command-timeout 600` (or whatever's reasonable for steady-state) so a recurrence won't burn 2 hours again.
4. **If the same task keeps stuck**: it's an ansible role / network issue, not a fleet-apply bug. Add `timeout: 300` or `async: 600 poll: 30` to the offending ansible task in `dot_ansible/roles/<role>/tasks/main.yml`.

`abandoned` state in `--status` (red, "no sentinel — wrapper SIGKILL'd?") means a previous run died abnormally — the wrapper got SIGKILL before its trap could write the exit sentinel. Common causes: parent OOM-killed, manual `kill -9`, or process-tree teardown cascading from a hung child. Treat it as a failure that left no recovery breadcrumb.

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
   `kill -9` on `scripts/fleet/apply.py`, or asyncssh closed the channel
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
- **Run looks dead after Ctrl+C** — when you Ctrl+C `scripts/fleet/apply.py`
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
  `scripts/**` is in `.chezmoiignore.tmpl` (so `scripts/fleet/apply.py` is never
  deployed to `$HOME` and only ever runs from the repo).
