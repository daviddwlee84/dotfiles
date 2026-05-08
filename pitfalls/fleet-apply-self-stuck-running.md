# `fleet-apply` shows `self` (local) host stuck "running" after chezmoi finishes

**Symptoms** (grep this section):
- `just fleet-apply` runs to completion on all remote hosts (rc=0, state=done),
  but the `self` (local) row keeps incrementing the `elapsed` clock indefinitely
  with `state=running`, `rc=-`
- The `last` column on `self` shows an early line of chezmoi output (e.g.
  `Already up to date.` from `chezmoi update`'s git-pull phase) — chezmoi itself
  *appears* to have finished, but the asyncio task never returns
- Ctrl+C produces this traceback:
  ```
  File ".../fleet_apply.py", line 699, in run_one_local
      await asyncio.gather(
  File ".../fleet_apply.py", line 688, in _drain
      line = await stream.readline()
  ...
  asyncio.exceptions.CancelledError
  ```
- The `self` row's elapsed is many minutes / hours
  (e.g. 2902s, 3359s) while remote hosts finished in seconds
- `pgrep -af 'chezmoi|ansible|brew'` on the local box shows live PIDs that
  outlived the parent `chezmoi update` process — typically ansible's `homebrew`
  task, a backgrounded `brew bundle install`, `mas install`, or a long-running
  ble.sh build/skill-install in `run_onchange_after_*.sh.tmpl`

**First seen**: 2026-05-08 on `Da-Weis-Mac-mini` (macOS 26.2 arm64), during
real-world testing of the new `fleet-status` readiness probe feature
(commit `015587f`). User confirmed manual kill required.
**Affects**: only `local = true` hosts (typically `self`). Remote hosts use the
SSH bash wrapper which carefully redirects fds via `> >(tee … & wait $_cz_pid;
echo $_rc > sentinel`, so they're immune.
**Status**: fixed in `run_one_local()` via two-phase wait — `os.kill(pid, 0)`
poll for chezmoi's actual exit, followed by 5s grace cancel of `_drain` tasks.
See "Fix" section below for why the obvious `proc.wait()`-based first attempt
also failed.

## Root cause

`run_one_local()` in `scripts/fleet_apply.py` (~line 603) spawns chezmoi via
`asyncio.create_subprocess_exec` with `stdout=PIPE` / `stderr=PIPE`, then awaits:

```python
async with asyncio.timeout(command_timeout):
    await asyncio.gather(
        _drain(proc.stdout, "out"),
        _drain(proc.stderr, "err"),
        proc.wait(),
    )
```

`_drain()` loops on `await stream.readline()` until EOF. The pipe only EOFs
when **every** process holding the write end of that pipe closes it.

chezmoi's `run_onchange_*` scripts inherit chezmoi's stdout/stderr fds. Some of
those scripts (notably `run_onchange_after_20_ansible_roles.sh.tmpl` and
`run_onchange_after_30_brew_bundle.sh.tmpl`) invoke commands that fork
sub-shells / daemons that **outlive their parent script** — for example:

- `brew install --cask ...` on macOS sometimes leaves a `Cask::Installer`
  background mover running
- ansible's `community.general.homebrew` calls `brew` synchronously, but a
  pre/post-install hook may daemonize
- `mas install <id>` polls App Store install state in the background
- `bashbot`/`gh extension install`/anything piping into `tee` that itself was
  started detached but inherited fd 1/2

Once chezmoi exits, `proc.wait()` resolves immediately with the rc. But
`_drain()` keeps blocking on `readline()` because the pipe still has live
writers. `asyncio.gather` waits for all three coroutines — so the gather
never returns, `status.finished_at` is never set in the `finally` block,
and the renderer keeps ticking the clock.

Counter-intuitively, the `state=running` is *correct from the script's
point of view* (the gather hasn't returned), but *misleading to the user*
(chezmoi finished long ago).

## Why remote hosts don't hit this

`build_remote_command()` wraps chezmoi in a bash one-liner:

```bash
> >(tee -a $log) 2>&1 & _cz_pid=$!; wait $_cz_pid; _rc=$?; echo $_rc > $sentinel
```

`wait $_cz_pid` only waits for chezmoi (PID 1 of the wrapper), NOT for any
backgrounded children. When chezmoi exits, the wrapper writes the sentinel
and exits. SSH closes the channel. Any orphaned children become detached
from the SSH channel's fds.

The local path doesn't have this wrapper because there's no shell layer
between Python and chezmoi.

## Fix sketch (proposed)

Three options, in increasing complexity:

1. **Don't wait for streams after `proc.wait()` returns.** Use
   `asyncio.wait(..., return_when=FIRST_COMPLETED)` keyed on `proc.wait()`,
   then cancel the `_drain` tasks once the process exits. Drain whatever's
   buffered before cancel. Risk: lose the last few lines of stdout if they
   weren't yet read. **DOESN'T WORK**: see "Why option 1 fails" below.

2. **Wrap local execution in the same bash sentinel pattern.** Spawn
   `bash -c '<chezmoi cmd> > >(tee -a $log) 2>&1 & _cz_pid=$!; wait $_cz_pid;
   echo $_rc > $sentinel'`. Adds quoting complexity but unifies local + remote
   code paths. Lose the structured `[out]`/`[err]` prefixing in the per-host
   log.

3. **Add a stuck-stream watchdog using `os.kill(pid, 0)` polling.** Don't
   trust `proc.wait()` — poll the actual OS-level process existence at 100ms
   intervals. Once chezmoi is gone, give `_drain` 5s to flush, then cancel
   them. Most pragmatic; preserves logs and structured prefix. **Shipped.**

### Why option 1 fails (the false-summit)

The obvious "use `await proc.wait()` and key the gather on FIRST_COMPLETED"
fix is wrong. `asyncio.subprocess.Process.wait()` doesn't actually wait for
the OS-level process exit — it waits for the asyncio
`SubprocessTransport` to fire `_process_exited`, which only happens when:

- `proc.returncode` is set (= SIGCHLD has fired and the child has been reaped), AND
- ALL of stdin/stdout/stderr pipes have closed

The second condition is the killer. When chezmoi's grandchildren inherit our
stdout/stderr fds and outlive chezmoi, the pipes never close, and
`proc.wait()` blocks just as hard as `_drain()` does — even though
`/proc/<pid>` no longer exists.

Verified empirically with this synthetic test:

```python
proc = await asyncio.create_subprocess_exec(
    "bash", "-c", "(sleep 60 && echo orphan-finally-exited) & echo parent-done",
    stdout=PIPE, stderr=PIPE,
)
t0 = time.monotonic()
await proc.wait()  # ← actually blocks 60s, NOT until bash exits
print(f"wait took {time.monotonic() - t0:.2f}s")  # 60.01s
```

Even though the bash parent exits in <100ms, `proc.wait()` blocks for the
full 60s until the orphan `sleep` releases stdout. Same root cause as the
original bug, one layer deeper.

### Shipped fix (option 3)

Replace `await proc.wait()` with a `kill(pid, 0)` polling helper:

```python
async def _wait_for_chezmoi_exit():
    while True:
        try:
            os.kill(proc.pid, 0)  # signal 0 = existence check, no signal sent
            await asyncio.sleep(0.1)
        except ProcessLookupError:
            # chezmoi is gone. Wait briefly for asyncio's child watcher
            # to set returncode (SIGCHLD reap), then return.
            for _ in range(50):  # up to 5s
                if proc.returncode is not None:
                    return
                await asyncio.sleep(0.1)
            return
```

Then 5s grace-cancel of the drain tasks, then `os.waitpid(WNOHANG)` as a
last-resort fallback if asyncio still hasn't seen the SIGCHLD (very rare).

Synthetic test: orchestrator returns in 2.1s instead of 60s, captures
`parent-done` correctly, identifies 2 orphan pipes via the warning log.

## Detection (for the future-me reading this)

Quick check from the host while `self` is stuck:

```sh
# Find the python orchestrator
pgrep -af fleet_apply

# Find what's still holding open the inherited fds
lsof -p <orchestrator_pid> | grep -i pipe

# Find the orphan children
pgrep -af 'chezmoi|ansible|brew|mas|gh' | grep -v fleet_apply
```

If `pgrep` shows ansible/brew/mas processes with `etime` > the chezmoi run
time, those are the orphans holding the pipe.

## Related

- `pitfalls/sudo-shared-setsid-macos.md` — also a fd/process-lifetime gotcha
- `backlog/fleet-status-init-in-progress-state.md` — sibling fleet-status bug
- Commit `015587f` — introduced `fleet-status`, regression-tested via
  real-world apply that surfaced this bug
