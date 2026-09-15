# `copilot-proxy start`/`update` dies with `bun:sqlite` `error: Out of memory` in `db.serialize()`

**Symptoms** (grep this section):
- Every `copilot-proxy start` (and every `copilot-proxy update <ver>`) prints the
  package download line, then a raw Bun stack trace and stops:
  ```
  copilot-proxy: downloading and verifying @jeffreycao/copilot-api@2.5.2 ...
  1 |
  2 |         import { Database } from "bun:sqlite";
  3 |         const db = new Database(process.argv[1], {readonly:true});
  4 |         db.exec("BEGIN");
  5 |         await Bun.write(process.argv[2], db.serialize());
                                                ^
  error: Out of memory
        at .../[eval]:5:45

  Bun v1.3.13 (macOS arm64)
  ```
- `copilot-proxy update` additionally reports `recovery snapshot failed; old
  package retained.` and leaves the old version in place.
- `copilot-proxy status` then reports `not running`, and the failure repeats on
  every start — it is a stable wedge, not a flake.
- The SQLite files it chokes on are *small* (tens of MB): here
  `~/.local/share/copilot-api/copilot-api.sqlite` was 31 MB and
  `~/.local/state/copilot-proxy/metrics.sqlite` 21 MB. This is not a real
  out-of-memory condition.

**First seen**: 2026-09-15
**Affects**: `dot_config/shell/43_copilot_proxy.sh` `_copilot_snapshot_runtime`,
on Bun 1.3.x (reproduced on 1.3.13, macOS arm64). The snapshot is on the critical
path of **both** `start` (via `_copilot_ensure_pkg`, whenever the pinned build is
not yet marked `.verified-integrity`/`.installed-spec`) and `update`.
**Status**: fixed 2026-09-15 — snapshot copies the DB files instead of serialising.

## Root cause

`bun:sqlite`'s `Database.serialize()` throws `error: Out of memory` on Bun 1.3.x
even for a 20–30 MB database. Reproduced directly, and it fails **with or
without** the wrapping `db.exec("BEGIN")` and with a `{readonly:true}`
connection — so it is the `serialize()` call itself, not the transaction or the
open mode. A plain `cp` of the same file, and `PRAGMA integrity_check` on the
copy, both succeed.

`_copilot_snapshot_runtime` used `serialize()` to fold each DB into a single file
inside the rollback bundle. Because that snapshot ran before the package swap and
returned non-zero on failure, the OOM aborted the swap: the new build never got
its `.installed-spec`/`.verified-integrity` markers written, so `_copilot_pkg_ready`
stayed false and the *next* start re-entered the same re-stage → snapshot → OOM
loop.

The snapshot never even needed `serialize()`: `_copilot_restore_generation`
restores the package, `selection.json` and the transport config, but **does not
restore the DB snapshots at all** — they are forensic copies only. (The bats test
`offline rollback ... preserves newer credentials and usage` asserts exactly this:
usage written *after* the update survives rollback, i.e. the live DB is never
rolled back.)

## Fix

Replace the `bun … db.serialize()` block with a plain file copy of the main DB
plus any `-wal`/`-shm` sidecars:

```sh
for ext in '' '-wal' '-shm'; do
  [ ! -f "$f$ext" ] || command cp -p "$f$ext" "$bundle/$label.sqlite$ext" || exit 1
done
```

This is safe because **every snapshot call site has already quiesced the writers**:
`start()` snapshots before the backend process spawns, and `update()` runs
`copilot-proxy stop` first. Copying the main file together with its WAL/SHM
sidecars yields a snapshot that replays cleanly on reopen (verified with
`PRAGMA integrity_check` → `ok`). It removes the Bun dependency from the snapshot
path entirely, so it cannot OOM.

## Manual recovery on an unpatched host

The package is only swapped *after* the snapshot, so a wedged host still has the
old working build in `pkg`; it just can't get past the snapshot. Either:

```console
# Pull the fixed wrapper, then start normally:
$ chezmoi update --apply && source ~/.config/shell/43_copilot_proxy.sh
$ copilot-proxy start
```

or, to stay on the old build without the fixed wrapper, pin it so `start` skips
the re-verify/snapshot path (writes `.installed-spec` for the installed version):

```console
$ copilot-proxy update <installed-version>   # e.g. the 2.3.4 already in pkg
```

Failed runs leave `pkg.stage.*` / `pkg.rollback.*` temp dirs under
`~/.local/share/copilot-api/`; they are safe to delete once a start succeeds
(keep `pkg` and the single `pkg.rollback.*` named in
`~/.local/state/copilot-proxy/rollback`).

## Generalisable

**Do not put a fragile, best-effort backup on the critical path of a state
transition, and never let a forensic-only artifact be able to abort the
operation it is merely recording.** The DB snapshot is never read back by
rollback; its failure should have been at worst a warning. Because it sat before
the package swap and was fatal, one library bug turned "take a backup" into "the
service can never start." When a step's only product is a diagnostic copy, copy
the bytes directly and keep it off the path that gates real work.

## See also

- [`copilot-proxy-stale-package-lock-integrity.md`](copilot-proxy-stale-package-lock-integrity.md) — the other place the verify/stage path wedges start
- [`copilot-proxy-shim-eaddrinuse-stale-build.md`](copilot-proxy-shim-eaddrinuse-stale-build.md) — the shim half of the launcher
