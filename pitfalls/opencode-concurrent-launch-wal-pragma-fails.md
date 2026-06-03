# Launching several `opencode` at once: `Failed to run the query 'PRAGMA journal_mode = WAL'`

**Symptoms** (grep this section):
- `Error: Unexpected error, check log file at /home/<user>/.local/share/opencode/log/<ts>.log for more details`
- `Failed to run the query 'PRAGMA journal_mode = WAL'`
- One (or more) `opencode` TUIs exit immediately on startup while sibling
  instances launched at the same moment come up fine
- Hits reliably when spawning multiple `opencode` instances simultaneously —
  e.g. `svibe N opencode`, a tmuxp/zellij layout, or a shell loop
- log shows several `service=db ... opencode.db opening database` lines within
  tens of milliseconds of each other

**First seen**: 2026-06 (opencode 1.4.6)
**Affects**: opencode (single global SQLite DB at `~/.local/share/opencode/opencode.db`); any concurrent-launch path. Not a `svibe`/dotfiles code bug — `svibe` only triggers it by starting N instances at once.
**Status**: upstream concurrency limitation; mitigation = stagger launches (`svibe` adds a small inter-pane delay, env `SVIBE_LAUNCH_STAGGER`)

## Symptom

```
❯ svibe 4 opencode
# one pane:
Error: Unexpected error, check log file at /home/taa/.local/share/opencode/log/2026-06-02T075227.log for more details
Failed to run the query 'PRAGMA journal_mode = WAL'
[opencode exited — back in shell. Re-run with: opencode]
# other panes: opencode TUI up and running
```

The log shows N instances opening the **same** database almost simultaneously:

```
INFO  ...+775ms service=default version=1.4.6 ... opencode
INFO  ...+832ms service=default version=1.4.6 ... opencode
INFO  ...+828ms service=default version=1.4.6 ... opencode
INFO  ...+64ms  service=db path=/home/taa/.local/share/opencode/opencode.db opening database
INFO  ...+66ms  service=db path=/home/taa/.local/share/opencode/opencode.db opening database
INFO  ...+69ms  service=db path=/home/taa/.local/share/opencode/opencode.db opening database
```

## Root cause

opencode keeps a single **global** SQLite database at
`~/.local/share/opencode/opencode.db` (with `-wal` / `-shm` sidecars). Each
opencode process spins up its own server that opens that DB on startup and runs
`PRAGMA journal_mode = WAL`.

Switching a database into WAL mode needs a brief **exclusive** lock. When
multiple instances open the DB within the same few milliseconds, one acquires
the lock to flip journal mode while the others get `SQLITE_BUSY`; opencode does
not retry/back-off here, so the loser throws the unhandled
`Failed to run the query 'PRAGMA journal_mode = WAL'` and exits.

This is purely about **simultaneous** startup. Opening opencode instances a
fraction of a second apart (the normal interactive case) never races, which is
why this only shows up under fan-out launchers like `svibe N opencode`.

## Workaround

**Stagger the launches** so each instance finishes its WAL pragma before the
next opens the DB. `svibe` now sleeps a short interval between agent panes:

```sh
# default 0.25s between panes; tune or disable via env
SVIBE_LAUNCH_STAGGER=0.4 svibe 4 opencode
SVIBE_LAUNCH_STAGGER=0   svibe 4 opencode   # disable (old simultaneous behavior)
```

Manual recovery for a pane that already lost the race: just re-run `opencode`
in that pane (the `--on-exit shell` hint leaves you in a shell). By then the
other instances have finished initializing the DB, so the retry succeeds.

If you hit it outside `svibe`, insert a `sleep 0.25` between your `opencode`
invocations, or start them serially.

## Prevention

- Any launcher that fans out N copies of a SQLite-backed TUI (opencode today;
  watch for others) should stagger startup rather than fire them in the same
  instant.
- Don't "fix" this by deleting `opencode.db-wal` / `-shm` — they're live WAL
  sidecars; removing them mid-run can lose uncommitted data.
- A single-instance-per-DB tool fundamentally can't be parallel-cold-started
  safely; staggering is a mitigation, not a guarantee. If opencode adds a
  busy-timeout / retry on the WAL pragma upstream, this can be dropped.

## Related

- `dot_config/shell/22_sesh.sh` — `sesh-vibe` launch-stagger mitigation
  (`SVIBE_LAUNCH_STAGGER`)
- [`pitfalls/zsh-star-slice-substring-not-element.md`](zsh-star-slice-substring-not-element.md)
  — the *other*, unrelated error from the same `svibe 4 opencode` run (first
  pane ran `o`)
- [`pitfalls/opencode-tool-execution-aborted-on-long-write.md`](opencode-tool-execution-aborted-on-long-write.md),
  [`pitfalls/opencode-docker-opentui-glibc-loader-missing.md`](opencode-docker-opentui-glibc-loader-missing.md)
  — other opencode traps
- SQLite WAL docs: <https://www.sqlite.org/wal.html> (mode switch needs an
  exclusive lock)
