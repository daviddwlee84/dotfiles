# agent-warmup scheduled run hangs, exits early, or leaves a blank pane under launchd/pueue

**Symptoms** (grep this section): a launchd / pueue / systemd-scheduled `agent-warmup run`
wedges for hours with `state = running` / `last exit code = (never exited)` and
no run log; OR completes (exit 0) but the run log's `## /usage panel` and
`## final pane capture` are EMPTY; OR `pueue status` shows the task stuck on
`Running`; `sample <pid>` shows the process pinned in
`dyld4::SyscallDelegate::mapFileReadOnly` / `withReadOnlyMappedFile`; the stuck
process is `uv` (no Python child) or `python3 .../agent-warmup run`; the warmup's
tmux session exists but `tmux capture-pane` returns only blank lines; the exact
same `agent-warmup verify` works perfectly when run by hand in a terminal.
**First seen**: 2026-06-20 (bringing up `agent-warmup` on a Mac mini)
**Affects**: macOS background launch contexts (launchd `gui/uid` agents, `pueued`
daemon) spawning an interactive `claude` TUI. Likely any tool launching a fresh
GUI-bound TUI from a daemon bootstrap.
**Status**: fixed in `agent-warmup` (four original traps plus the 2026-08-25
uv-first bootstrap correction below)

## 2026-08-25 correction: uv is not categorically daemon-unsafe

A controlled PEP 723 + Tyro probe succeeded with the existing standalone
`uv 0.9.24` through both pueue and a temporary macOS `gui/502` LaunchAgent when
invoked as:

```text
uv run --quiet --no-project --no-env-file --offline \
  --python /usr/local/bin/python3 --script <script> ...
```

That isolates the script from the repo `.venv`, pins a main-volume interpreter,
and requires a pre-warmed cache. The old finding remains valid for the original
unqualified shebang/secondary-volume setup, but "never use uv from a daemon" is
too broad.

Current scheduled jobs therefore enter through main-volume Python and a hidden
stdlib bootstrap. It tries the exact uv command above, waits up to 30 seconds
for a startup sentinel written immediately before core side effects, and only
then falls back to the stdlib core. A post-sentinel failure never falls back, so
Claude cannot receive the warmup prompt twice. Runtime is recorded as `uv` or
`direct-fallback`; probe diagnostics append to
`~/.cache/agent-warmup/uv-bootstrap.log`.

## Four stacked traps, each masking the next

Debugging found FOUR separate failures, only visible one at a time:

1. **`uv run` shebang hangs under launchd.** The first scheduled run wedged in
   the `uv` launcher itself (the stuck PID was `uv`, no Python child, stuck in
   dyld) before Python started — no session, no log, no exit.
   → Original fix: invoke a main-volume Python directly. Current fix: retain
   that Python as the stdlib bootstrap, then run uv with the isolated flags and
   pre-side-effect sentinel described above.

2. **`import plistlib` → `pyexpat.so` stalls in amfid.** Loading a C-extension
   `.so` triggers macOS `amfid` code-signature verification, which can deadlock
   under a daemon bootstrap (and `amfid` got wedged by repeated rapid launches).
   → Fix: `plistlib` is only needed by `install` (always interactive); make it a
   lazy import so the scheduled `run` hot path never loads it.

3. **The uv-managed Python lives on a secondary volume.** `lsof` showed the
   interpreter at `/Volumes/Data/.../uv-share/python/cpython-*/bin/python3.11`
   (a separate device). Memory-mapping its binary / `.so` files from that volume
   BLOCKS in `dyld mapFileReadOnly` under a daemon bootstrap — a volume-access
   gate the GUI session has but daemons don't. A trivial `python -c print` from
   the same interpreter ran fine; the full import set hung.
   → Fix: `_scheduled_python()` prefers a **main-volume** interpreter
   (`/opt/homebrew/bin/python3` or `/usr/local/bin/python3`); it is used by both
   the bootstrap and uv's exact `--python` selection.

4. **claude's TUI renders NOTHING in a daemon-created tmux server.** After the
   hangs were gone the run completed but the pane was blank: claude launched in a
   tmux server that a daemon created draws nothing (same env, same flags), and
   the session dies. But a daemon that CONNECTS to the user's already-running
   GUI-session tmux server and spawns claude *there* renders perfectly.
   → Fix: `run` injects a transient `warmup-<ts>` session into the user's
   **default** tmux server (no private `-L` socket) and kills only that session.

## How to tell which trap you hit

- Stuck PID is `uv`, no log → trap 1.
- Stuck `python`, `sample` in `mapFileReadOnly`, interpreter path under
  `/Volumes/...` → trap 3 (or trap 2 if it loaded a `.so` like `pyexpat`).
- Run finishes, log written, `/usage` panel empty → trap 4.

## Verify

```bash
agent-warmup at --delay 60s --verify     # pueue (daemon) path
# then read the newest ~/.cache/agent-warmup/run-*.log:
#   status: ok  AND a populated "## /usage panel" with "Current session ... Resets"
#   = claude rendered and the 5h subscription window advanced.
```

A `status: warning: blank pane` line (added by the fix) means trap 4 recurred —
check that a tmux server is running in the GUI session.

## Constraint that remains

The warmup borrows the GUI-session tmux server, so **a tmux server must be
running in the login session at warmup time**. If none exists and the caller is
not a TTY, `run` notifies and exits (it will not spawn a daemon-owned server,
which would only reproduce trap 4).

## References

- [docs/tools/agent-warmup.md](../docs/tools/agent-warmup.md)
- [headless-claude-p-does-not-move-5h-window.md](headless-claude-p-does-not-move-5h-window.md) (the billing reason warmup must be interactive at all)
- [backlog/agent-quota-warmup-at-time.md](../backlog/agent-quota-warmup-at-time.md)
