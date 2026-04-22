# `fleet_apply.py` vs. 2018-era Fabric (`fabfile.py`)

A side-by-side comparison between this repo's [`scripts/fleet_apply.py`](../../scripts/fleet_apply.py)
and the author's earlier
[RaspPi-Cluster `fabfile.py`](https://github.com/daviddwlee84/RaspPi-Cluster/blob/master/fabfile.py)
(Fabric 1.x, ~2018). Both solve the same shape of problem — one controller
fans a command out to N machines — but the implementations are separated by
~7 years of accumulated operational pain.

Kept here for "why does fleet-apply look the way it does?" archaeology.
Not required reading to use either tool.

## Same idea, both eras

| Concern | RaspPi-Cluster `fabfile.py` (Fabric 1.x) | `scripts/fleet_apply.py` (asyncssh) |
|---|---|---|
| Host inventory | `env.hosts` + `env.passwords` hard-coded at top of file | `~/.config/fleet/machines.toml` (`load_hosts`, [fleet_apply.py:101](../../scripts/fleet_apply.py#L101)) |
| Parallel fan-out | `@parallel` decorator (thread pool over paramiko) | `asyncio.TaskGroup` + semaphore (single-thread coroutines) |
| Sudo password injection | `env.passwords[host] = pw`; Fabric expects + feeds prompt | Pushed to remote `~/.cache/chezmoi-fleet/sudo.pass` (0600) + `CHEZMOI_SUDO_PASSWORD_FILE` ([fleet_apply.py:240](../../scripts/fleet_apply.py#L240)) |
| Remote command exec | `sudo()` / `run()` | `conn.create_process(cmd)` ([fleet_apply.py:807](../../scripts/fleet_apply.py#L807)) |
| ssh_config alias support | Native (Fabric shells out to OpenSSH) | asyncssh reads `~/.ssh/config` for the alias ([fleet_apply.py:550](../../scripts/fleet_apply.py#L550)) |
| Task framing | `fab install_dependencies` / `fab change_hostname` | `just fleet-apply` / `just fleet-apply-file PATH` |

If you only care about "one entry point, ssh a command to a list of boxes,
collect exit codes" — they're the same tool, different decade.

## What the 7 years bought

### 1. Concurrency model: threads → coroutines

- **Fabric 1.x**: `@parallel` spawns one OS thread per host (paramiko under the hood). Fine at 5–20 hosts; FD/stack pressure at hundreds.
- **fleet_apply.py**: single-thread `asyncio` + `asyncssh`. Scales further; semaphore (`--max-parallel`) bounds concurrency without thread overhead.

### 2. Process-tree cleanup on Ctrl+C / dropped channel

The fabfile does nothing — `Ctrl+C` on the controller leaves orphan
`apt-get` / `pip install` processes on every Pi.

`fleet_apply.py` triple-stacks the cleanup
([fleet_apply.py:430–486](../../scripts/fleet_apply.py#L430)):

1. `set -m` so each backgrounded child gets its own process group.
2. `trap 'pkill -TERM -P $_cz_pid; kill -TERM $_cz_pid' INT TERM HUP` in the wrapper.
3. asyncssh `request_pty=True` so closing the channel delivers SIGHUP to the remote shell, firing the trap.

Plus `--kill-orphans` as a janitor for the cases all three layers miss.

### 3. Observability after the controller dies

- **Fabric**: stdout interleaved across hosts; lose the terminal, lose the run.
- **fleet_apply.py**:
  - Per-run remote log at `~/.cache/chezmoi-fleet/logs/<run_id>.log` + `.exit` sentinel.
  - `--tail HOST[:RUN_ID]` reattaches to a still-running remote.
  - `--status [--watch N]` polls "is chezmoi/ansible still alive on each host?"
  - Local `logs/fleet-apply/<UTC>/<host>.log` mirrors the same stream.

### 4. Live UI

Rich `Live` table renders state / elapsed / rc / last-line per host as the run
progresses ([fleet_apply.py:897](../../scripts/fleet_apply.py#L897)). Fabric
just printed interleaved stdout.

### 5. Drift classification (chezmoi-specific)

`_classify_drift()` ([fleet_apply.py:520](../../scripts/fleet_apply.py#L520))
demotes a chezmoi `rc != 0` from `failed` to `drift` when the **only** stderr
lines are "could not open a new TTY" prompts — i.e. `--keep-going` skipped a
hand-edited target on the remote. The host shows yellow ⚠ and lists the
drifting paths, but **does not** count toward the exit code. See
[fleet-apply.md → "drift ≠ failed"](fleet-apply.md).

Fabric had no equivalent concept; rc != 0 was always failure.

### 6. Sudo session model

- **Fabric**: `env.passwords` lives in controller memory; every `sudo()` call re-expects the prompt and re-feeds the password.
- **fleet_apply.py**: password written **once** to a 0600 file on the remote, then [`scripts/lib/sudo_shared.sh`](../../scripts/lib/sudo_shared.sh) `sudo_session_init` adopts it via `sudo -S -v -p ''`. All 22+ ansible roles in the same `chezmoi apply` reuse the cached credential — no per-task expect dance. See [sudo-session.md](sudo-session.md) → "Non-interactive password injection".

### 7. Password sources

Fabric: plaintext-in-code only.

fleet_apply.py supports four ([fleet_apply.py:59](../../scripts/fleet_apply.py#L59)):

| Type | Behaviour |
|---|---|
| `plain` | Value in TOML (chmod the file) |
| `prompt` | `getpass()` once at startup, per host |
| `bitwarden` | `bw get password <item>` (requires unlocked vault + `BW_SESSION`) |
| `none` | No sudo (matches `noRoot=true` chezmoi init) |

### 8. Local host = same code path

`host.local = true` bypasses SSH and runs `chezmoi` as a local subprocess
([`run_one_local`, fleet_apply.py:597](../../scripts/fleet_apply.py#L597)),
sharing the orchestrator's PATH and tty/sudoers state. Same log layout,
same status/tail probes work on it.

Fabric required separate `local()` vs. `run()` codepaths.

### 9. Pager / TTY hardening

`--no-pager` + `PAGER=cat GIT_PAGER=cat` + **no PTY** for the chezmoi command
([fleet_apply.py:293–299](../../scripts/fleet_apply.py#L293)). Defends against:

- `bat` panicking on a missing theme when stdout isn't a terminal.
- `less` blocking forever waiting for input.
- chezmoi reading its own `pager` config key (ignores `PAGER` env var — that's why `--no-pager` is required).

These were all real failures encountered on this fleet; the fabfile era used
plain `apt-get` and didn't see them.

### 10. Branch / topic-branch workflow

`--branch BRANCH [--force-checkout]` checks out a feature branch in the
remote source dir before applying. Fabric had no concept of "the dotfiles
repo on each host has its own checkout".

## What Fabric did better

For honesty:

- **Setup cost**: `pip install fabric && fab task` — no asyncio, no Rich, no TOML schema. fleet_apply.py is a 1200-line uv self-installing script.
- **Imperative DSL**: Fabric let you write `sudo("apt install foo"); put("local.conf", "/etc/foo.conf"); run("systemctl restart foo")` inline. fleet_apply.py only runs **one** command (`chezmoi update`/`apply`/`diff`) because the per-host logic is delegated to chezmoi + ansible. If you want ad-hoc imperative ssh-fanout, Fabric (or its modern successor [Fabric 2.x](https://www.fabfile.org/) / `pyinfra`) is still the better fit.
- **Lower abstraction = less to learn**: `fab -H host1,host2 -- uname -a` works out of the box. fleet_apply.py needs a TOML file and a chezmoi setup.

## TL;DR

| | Fabric era (2018) | fleet_apply.py (now) |
|---|---|---|
| Solves | Push commands to N hosts | Push commands to N hosts |
| Concurrency | Thread pool | asyncio coroutines |
| Crash recovery | None — lose terminal, lose run | Remote logs + sentinels + `--tail` / `--status` / `--kill-orphans` |
| Sudo | Per-call expect | Once-per-host file + shared session |
| UI | Interleaved stdout | Rich live table |
| Failure semantics | rc != 0 = fail | rc != 0 demoted to `drift` when chezmoi-skip pattern matches |
| Secret sources | Plaintext-in-code | plain / prompt / bitwarden / none |
| Local host | Separate `local()` API | Same code path (`local = true`) |
| Lines of code | ~200 | ~1500 |

The DNA is identical. The new version is what happens when you let one tool
accumulate every "ugh, that bit me last week" fix for seven years.
