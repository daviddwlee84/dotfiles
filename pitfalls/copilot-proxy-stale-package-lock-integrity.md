# `copilot-proxy: installed package integrity does not match the trusted pin.` on every start

**Symptoms** (grep this section):
- `copilot-proxy start` / `restart` prints the install banner, then dies:
  ```
  copilot-proxy: installing @jeffreycao/copilot-api@2.3.0 (one-time — later starts skip this) ...
  copilot-proxy: installed package integrity does not match the trusted pin.
  ```
- It never gets past this — `copilot-proxy status` then says
  `not running on port 4141`, and `copilot-proxy logs` says
  `no log file at .../copilot-api-4141.log` (the proxy never launched, so there
  is nothing to read).
- Every managed launcher fails downstream of it:
  `codex-copilot` / `claude-copilot` / `codex-copilot-once` print
  `copilot-proxy: managed client refused to bypass the enabled metrics shim.`
- The *correct* version is nonetheless sitting on disk. That's the tell:
  ```console
  $ jq -r .version ~/.local/share/copilot-api/pkg/node_modules/@jeffreycao/copilot-api/package.json
  2.3.0
  ```

**First seen**: 2026-08-26
**Affects**: `dot_config/shell/43_copilot_proxy.sh` after `e0836c1`
("verified updates"), on any host whose install prefix had *ever* taken the npm
fallback path
**Status**: fixed 2026-08-26 — the lockfile read is version-gated

## Root cause

The guard in `_copilot_ensure_pkg` read the recorded npm integrity out of
`$prefix/package-lock.json` and compared it to the trusted pin. That comparison
is only meaningful when the lock describes the version that is actually
installed — and in this prefix it usually doesn't:

| Installer | Writes | Touches `package-lock.json`? |
|---|---|---|
| `bun add` (attempts 1 & 2, the normal path) | `bun.lock` | **no** |
| `npm install` (attempt 3, the CA-stack fallback) | `package-lock.json` | yes |

So one npm-fallback install — the rescue path for a Clash/TUN node that trips
Bun's `UNKNOWN_CERTIFICATE_VERIFICATION_ERROR` — leaves a `package-lock.json`
behind **permanently**. Every later `bun add` of a newer pin writes `bun.lock`
and leaves that file untouched, frozen at the old version:

```console
$ cd ~/.local/share/copilot-api/pkg && ls -l bun.lock package-lock.json
-rw-r--r--  40k 26 Aug 16:13 bun.lock            # bun installed 2.3.0
-rw-r--r--  37k 11 Aug 15:34 package-lock.json   # npm installed 2.1.0, months stale

$ jq -r '.packages["node_modules/@jeffreycao/copilot-api"] | .version, .integrity' package-lock.json
2.1.0
sha512-9/Ro1UzrYT/erB7eR/rf61XHFyc5TOwQ94B6ij/Wu91TD1hnmbuqYu/PavKGUQ7YDBVCXFENRRvQSpTkS0X3eA==
```

That hash is 2.1.0's, and it is genuine — it matches the registry exactly. The
pin is 2.3.0's, also genuine. The guard compared **2.1.0's real hash against
2.3.0's real hash**, called the difference tampering, and refused. Nothing was
compromised; the check was comparing two different versions.

It fails 100% of the time and is unrecoverable by retrying, because the failure
happens *before* `.installed-spec` is written — so `_copilot_pkg_ready` stays
false, and the next start re-installs and re-fails identically.

## Fix

Version-gate the lockfile read: it is evidence only when
`.packages[<pkg>].version` equals the version in
`node_modules/<pkg>/package.json`. Otherwise ignore the lock and fall through to
the npm-registry metadata comparison, which is keyed on the **installed**
version rather than on the spec string.

Both failure messages now print what was actually compared, so the next
occurrence is one line to diagnose instead of a bisect:

```
copilot-proxy: installed package integrity does not match the trusted pin.
  on disk: @jeffreycao/copilot-api@2.1.0   pinned: @jeffreycao/copilot-api@2.3.0
```

## Manual recovery on an unpatched host

```console
$ rm ~/.local/share/copilot-api/pkg/package-lock.json   # stale, bun does not use it
$ copilot-proxy start
```

## Generalisable

**A lockfile from package manager A is not evidence about an install performed
by package manager B.** Any integrity/version guard that reads a lockfile must
first confirm the lockfile describes the tree it is standing in — mixed-manager
prefixes are normal wherever a fallback installer exists, and the stale artifact
outlives the condition that created it by months.

**Corollary**: put the verify step *after* the idempotence stamp only if the
stamp records failure too. Here the stamp write was gated behind the check, so a
false positive was self-perpetuating rather than self-healing.

## See also

- [`copilot-proxy-start-hangs-at-resolving-dependencies.md`](copilot-proxy-start-hangs-at-resolving-dependencies.md) — why there is an install prefix (and an npm fallback) at all
- [`copilot-proxy-shim-eaddrinuse-stale-build.md`](copilot-proxy-shim-eaddrinuse-stale-build.md) — the other half of the same broken session
