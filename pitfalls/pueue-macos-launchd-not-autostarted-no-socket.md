# `pueue` on macOS: "Couldn't find a configuration file" / "connecting to daemon … No such file or directory" even after `brew services start`

<!-- Symptom = the client can't reach the daemon (no config, then no socket);
     root cause = the Homebrew formula ships `keep_alive false` + RunAtLoad-only,
     and launchd doesn't actually execute pueued after a `brew services` toggle
     that coincides with an upgrade/relink. Grep terms: "Couldn't find a
     configuration file", "Did you start the daemon yet", "pueue_david.socket",
     "connecting to daemon", "OnDemand", "keep_alive", "kickstart", "brew
     services start pueue". -->

**Symptoms** (grep this section):

- `pueue` / `pueue status` on macOS aborts with:
  ```
  Error:
     0: Couldn't find a configuration file. Did you start the daemon yet?

  Location:
     pueue/src/bin/pueue.rs:61
  ```
- After `brew services start pueue` (which reports **`Successfully started`**),
  the *same* command now fails one step later — no longer "no config" but "no
  socket":
  ```
  Error:
     0: Failed to initialize client.
     1: Failed to initialize stream.
     2: I/O error at path "/Users/<you>/Library/Application Support/pueue/pueue_<you>.socket" while connecting to daemon. Did you start it?:
        No such file or directory (os error 2)

  Location:
     /private/tmp/pueue-.../pueue_lib/src/network/client.rs:85
  ```
- `ps aux | grep pueued` is **empty** — no daemon process, despite brew saying it started.
- `launchctl list homebrew.mxcl.pueue` shows the job **loaded but not running**:
  ```
  {
      ...
      "OnDemand" = true;      ← launchd thinks it's on-demand, waits for a trigger
      "LastExitStatus" = 0;   ← exit 0, so nothing looks broken
      "Label" = "homebrew.mxcl.pueue";
      "Program" = "/usr/local/opt/pueue/bin/pueued";
  }
  ```
  (no `"PID" = …` line = not currently executing)
- `brew services list` → `pueue  none` (or a green `started` that still has no
  live process behind it).
- The daemon binary is **fine** — running it in the foreground works instantly:
  ```
  $ /usr/local/opt/pueue/bin/pueued --verbose
  ... Using unix socket at: ".../Library/Application Support/pueue/pueue_<you>.socket"
  $ pueue status        # in another shell → "Group \"default\" (1 parallel): running"
  ```
- Red herring: you go looking for `~/.config/pueue/` and it doesn't exist — that
  is **normal on macOS** (see root cause), not the bug.

**First seen**: 2026-07 on `David-MacBook` (Intel, `/usr/local`), pueue 4.0.4,
immediately after `brew upgrade pueue && brew services start pueue` in one shot.
**Affects**: any macOS host that starts pueue via `brew services` — Intel
(`/usr/local/opt/pueue`) and Apple Silicon (`/opt/homebrew/opt/pueue`). Most
likely to bite when `brew services start` runs **in the same moment as an
upgrade/relink**, so the `RunAtLoad` kick doesn't land. Normally invisible
because `RunAtLoad` fires at login and you never notice `keep_alive` is off.
**Status**: not a repo bug and not broken — Homebrew's `pueue` formula
intentionally sets `keep_alive false`. Workaround = one `launchctl kickstart -k`.
No repo change needed; `docs/tools/pueue.md` install note updated to point here.

## Root cause

Two facts combine into a self-deadlock:

1. **macOS config/socket path is NOT `~/.config/pueue/`.** pueue 4.x on macOS
   uses the Apple-native dir `~/Library/Application Support/pueue/`
   (`pueue.yml`, `state.json`, `certs/`, and the `pueue_<user>.socket`). The
   daemon auto-generates it on first successful start. So "Couldn't find a
   configuration file" really means *the daemon was never up long enough to
   create it* — the client just reports the missing config first, then (once a
   `pueue.yml` exists but the daemon still isn't running) reports the missing
   **socket**. Both messages are the **same underlying problem**: no live daemon.

2. **The Homebrew formula ships `keep_alive false` + `RunAtLoad` only, with no
   `Sockets` key.** From `Formula/p/pueue.rb`:
   ```ruby
   service do
     run [opt_bin/"pueued", "--verbose"]
     keep_alive false        # ← deliberate; pueued shouldn't be blindly respawned
     working_dir var
     log_path var/"log/pueued.log"
     error_log_path var/"log/pueued.log"
   end
   ```
   The generated `~/Library/LaunchAgents/homebrew.mxcl.pueue.plist` therefore has
   `RunAtLoad=true` but **no `KeepAlive`** and **no `Sockets`** stanza. In
   launchd's eyes the job is `OnDemand=true`. But pueue's socket is created **by
   the daemon itself**, not socket-activated by launchd. So if the single
   `RunAtLoad` execution doesn't actually fire (which is what happens when
   `brew services start` coincides with the relink of an upgrade), you land in a
   deadlock: **no daemon → no socket → and launchd is waiting for socket activity
   that will never come to start the daemon.** `LastExitStatus = 0` and an empty
   `pueued.log` (the log file is never even created) confirm the daemon **never
   ran this load**, rather than crashed.

Why `brew services restart` doesn't reliably fix it: `restart` re-loads the job
but hits the same `RunAtLoad`-vs-OnDemand timing; without `KeepAlive` there's
nothing forcing an actual `pueued` exec.

## Workaround

Force launchd to *execute* the job right now (`-k` kills any half-loaded
instance first, then starts fresh):

```sh
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.pueue
```

Verify:

```sh
ps aux | grep -v grep | grep pueued                       # → pueued --verbose <PID>
launchctl list homebrew.mxcl.pueue | grep '"PID"'         # → "PID" = <n>;
ls -la ~/Library/Application\ Support/pueue/*.socket      # → pueue_<you>.socket exists
pueue status                                              # → Group "default" (1 parallel): running
```

If `kickstart` isn't available (very old macOS) or you'd rather not involve
launchd at all, just run the daemon directly — this always works because the
binary is not the problem:

```sh
pueued -d        # daemonize; dies on reboot, but no launchd timing games
```

To fully re-seat the launchd job (rarely needed — try `kickstart -k` first):

```sh
launchctl bootout   gui/$(id -u)/homebrew.mxcl.pueue 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/homebrew.mxcl.pueue.plist
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.pueue
```

## Prevention

- **Don't chase the config path.** On macOS the files live in
  `~/Library/Application Support/pueue/`, never `~/.config/pueue/`. A missing
  `~/.config/pueue/` is expected, not the fault.
- **Read the launchd state, not brew's "Successfully started".** `brew services`
  reporting success only means the job *loaded*. Confirm with
  `launchctl list homebrew.mxcl.pueue` — a live daemon has a `"PID"` line; a
  bare `"OnDemand" = true` with no PID means it loaded but never executed.
- **After a `brew upgrade pueue` that you follow with `brew services start`,**
  assume the `RunAtLoad` kick may not land and just run
  `launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.pueue` once. Cheap and
  idempotent.
- **Don't "fix" this by editing the brew plist to add `KeepAlive`.** It's not a
  repo-managed file — `brew services` / the next `brew upgrade` will regenerate
  it from the formula's `keep_alive false`, silently dropping your edit. If a
  boot-persistent, self-healing daemon ever becomes a real requirement, the
  clean route is a chezmoi-managed LaunchAgent under
  `~/Library/LaunchAgents/` (this host is chezmoi-managed) — but that's a
  deliberate override to add on request, not a bugfix, and it must displace the
  brew service to avoid two jobs racing the same socket. Not done today because
  a single `kickstart` covers the one-off timing glitch and normal logins start
  it fine.

## Related

- Linux sibling: [`centos7-systemd-user-instance-missing.md`](centos7-systemd-user-instance-missing.md)
  — the *other* "pueued daemon never starts under the init system" trap, but a
  different root cause (RHEL 7 systemd 219 lacks the `user@.service` template, so
  `systemctl --user` can't bring up the user-scope daemon at all). macOS =
  launchd timing (recoverable with one command); CentOS 7 = missing feature
  (WONTFIX, run under tmux/nohup). Both conclude "the daemon binary is fine; the
  service manager is the problem."
- Adjacent launchd+pueue trap: [`agent-warmup-scheduled-run-hangs-or-blank-under-daemon.md`](agent-warmup-scheduled-run-hangs-or-blank-under-daemon.md)
  — a *scheduled* pueue/launchd job that runs but wedges or finishes blank
  (`dyld mapFileReadOnly` under the daemon session); different failure shape,
  same "works by hand, misbehaves under the macOS service manager" family.
- Sibling `brew services` / launchd-doesn't-do-what-you-think family on macOS:
  [`ollama-brew-link-fails-cask-shadows-formula.md`](ollama-brew-link-fails-cask-shadows-formula.md),
  [`brew-bundle-redownloads-manually-installed-cask.md`](brew-bundle-redownloads-manually-installed-cask.md).
- Tool docs: [`docs/tools/pueue.md`](../docs/tools/pueue.md) → "Install" note
  (the "not autostarted on macOS" line links back here).
- Upstream formula: Homebrew `Formula/p/pueue.rb` `service do … keep_alive false`.
