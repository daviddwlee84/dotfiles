# Shared sudo session re-prompts once per run-script on macOS (`setsid` missing)

**Symptoms** (grep this section):
- On macOS, `chezmoi apply` (or `chezmoi update --init`) prompts three times
  in a row — once per run-script — despite the "entered once, reused for this
  chezmoi apply" wording:
  ```
  [bootstrap] sudo password for <user> (entered once, reused for this chezmoi apply):
  …
  [ansible]   sudo password for <user> (entered once, reused for this chezmoi apply):
  …
  [brew]      sudo password for <user> (entered once, reused for this chezmoi apply):
  ```
- `which setsid` on macOS: `setsid not found`
- `man 2 setsid` exists (libc system call), but `setsid(1)` does not ship in
  base macOS
- Between prompts, `$TMPDIR/chezmoi-sudo-$UID/` exists with valid `sudo.pass`
  / `ansible-become.yml` / `keepalive.pid`, but the PID in `keepalive.pid` is
  dead: `kill -0 $(cat …/keepalive.pid)` returns non-zero, `ps -p <pid>`
  returns no row
- Linux hosts (Ubuntu, Debian) are unaffected — util-linux ships `setsid(1)`
- No `setsid: command not found` error is visible to the user because the
  failing command is backgrounded with `>/dev/null 2>&1 &`

**First seen**: 2026-04 on `Da-Weis-Mac-mini` (macOS 26.2 arm64, chezmoi 2.69.4)
**Affects**: any macOS host running `scripts/lib/sudo_shared.sh` without
util-linux installed from Homebrew. Introduced when the shared-sudo helper
landed.
**Status**: fixed in `scripts/lib/sudo_shared.sh` (`_sudo_spawn_watchdog`
falls back to `nohup` when `setsid` is unavailable).

## Symptom

The helper's contract is "prompt once at the start of `chezmoi apply`,
downstream run-scripts reuse the cached credential silently" (see
[CLAUDE.md → Sudo session is shared across all run-scripts](../CLAUDE.md)).
On macOS the prompt fires three separate times — once for `bootstrap`, once
for `ansible`, once for `brew` — with the state dir being wiped and rebuilt
between each.

The state on disk during the second prompt looks "valid":

```
$ ls -la "$TMPDIR/chezmoi-sudo-$(id -u)"
.rw-------@ 36 daviddwlee84 25 Apr 03:59  ansible-become.yml
.rw-------@  6 daviddwlee84 25 Apr 03:59  chezmoi.pid
.rw-------@  6 daviddwlee84 25 Apr 03:59  keepalive.pid
.rw-------@  9 daviddwlee84 25 Apr 03:59  sudo.pass

$ PID=$(cat "$TMPDIR/chezmoi-sudo-$(id -u)/keepalive.pid")
$ kill -0 "$PID" 2>&1 || echo DEAD
DEAD
$ ps -p "$PID"
  PID TTY           TIME CMD       # empty — process long gone
```

`sudo.pass` is correct; `ansible-become.yml` is correct; the watchdog is the
only broken piece.

## Root cause

`_sudo_spawn_watchdog` in `scripts/lib/sudo_shared.sh` spawned the keepalive
watchdog via:

```bash
setsid bash -c '…' _ "$state_dir" "$watch_pid" </dev/null >/dev/null 2>&1 &
local pid=$!
```

The goal was "new session, detached from the controlling TTY, survives the
invoking run-script's exit." On Linux `setsid(1)` does that. On macOS there
is no `setsid(1)` in base — Apple ships `setsid(2)` as a libc system call
(accessible from C, Python's `start_new_session=True`, etc.) but no CLI
wrapper. Homebrew has a keg-only `util-linux` formula which would provide
it, but this repo doesn't force-link it and most Macs don't have it.

When `setsid` isn't on `$PATH`, the backgrounded invocation does this:

1. Shell forks a child to run `setsid bash -c '…' &`
2. The child tries to `execvp("setsid", …)`, fails with `ENOENT`
3. Child prints `setsid: command not found` → redirected to `/dev/null` →
   invisible
4. Child exits with status 127 → zombie reaped by shell
5. Parent sets `pid=$!` to that dead child's PID (correct PID, dead process)
6. Parent writes that PID into `keepalive.pid`

On the next run-script, `_sudo_state_valid` checks:

```bash
kill -0 "$pid" 2>/dev/null || return 1   # ← fails here: PID is dead
```

Returns non-zero → `sudo_session_init` thinks the state is stale → line 236
`rm -rf "$dir"` wipes the still-valid password files → re-prompt.

The `sudo -S -v -p ''` validation a few lines later (line 110) would have
worked — `sudo.pass` is fine — but the `kill -0` check runs first and
short-circuits.

## Workaround

Fixed in-tree. The fix in `scripts/lib/sudo_shared.sh` is to detect `setsid`
at runtime and fall back to `nohup` on systems without it:

```bash
if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$body" _ "$state_dir" "$watch_pid" </dev/null >/dev/null 2>&1 &
else
    nohup bash -c "$body" _ "$state_dir" "$watch_pid" </dev/null >/dev/null 2>&1 &
fi
```

Plus `trap "" HUP` at the top of the child body so SIGHUP on controlling-TTY
hangup is ignored even in the `nohup` branch (belt-and-suspenders — `nohup`
already does this, but making it explicit in the body means the behaviour
is identical between the two branches).

`nohup` is in base macOS (`/usr/bin/nohup`) and in util-linux on Linux, so
this fallback is universally available. It doesn't create a new session
like `setsid` does, but for the actual requirement here ("survive the
parent run-script's exit") the `&` + `disown` + stdin/stdout/stderr-to-
`/dev/null` + SIGHUP-ignored combination is sufficient.

Verification on a fresh `chezmoi apply` after the fix:

```bash
$ grep -c 'sudo password' <apply-log>    # should be 1, not 3
1

$ PID=$(cat "$TMPDIR/chezmoi-sudo-$(id -u)/keepalive.pid")
$ kill -0 "$PID" && echo alive
alive
```

If you're debugging a machine that already has the stale state dir, wipe it
manually before the next apply:

```bash
rm -rf "${TMPDIR:-/tmp}/chezmoi-sudo-$(id -u)"    # or $XDG_RUNTIME_DIR on Linux
```

## Prevention

- Any new "detach a long-lived helper from this shell" in this repo must
  either use the pattern above (setsid-with-nohup-fallback) or go through
  a launchd agent. Don't add raw `setsid` calls to new shell scripts.
- When reviewing future edits to `scripts/lib/sudo_shared.sh`, check the
  watchdog spawn on macOS too — Linux CI passes silently for this class of
  bug because `setsid` always works there. The CLAUDE.md invariant "Sudo
  session is shared across all run-scripts" covers the `sudo -k` footgun
  but not the silent-watchdog-death footgun; this pitfall is the record.
- Long-term option: install util-linux via Homebrew in the ansible
  `devtools` role on macOS, symlink `setsid` into `~/.local/bin`. Not
  worth the keg-only linking complexity right now; the `nohup` fallback is
  simpler and less invasive.

## Related

- [CLAUDE.md → Sudo session is shared across all run-scripts](../CLAUDE.md) —
  the invariant this pitfall is a failure mode of
- [`docs/this_repo/sudo-session.md`](../docs/this_repo/sudo-session.md) —
  helper API, state dir layout, cleanup model
- [`scripts/lib/sudo_shared.sh`](../scripts/lib/sudo_shared.sh) —
  `_sudo_spawn_watchdog` is where the fix lives
- Apple's `setsid(2)` man page confirms the syscall exists but a CLI
  wrapper is not shipped — this is Apple's choice, not an oversight, so
  the workaround needs to live in this repo indefinitely
