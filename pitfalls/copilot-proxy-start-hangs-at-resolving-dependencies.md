# `copilot-proxy start` hangs at "Resolving dependencies" and never binds the port

**Symptoms** (grep this section): `copilot-proxy: did not come up in time — check 'copilot-proxy logs'.`; `copilot-proxy logs` shows only `nohup: ignoring input` + `Resolving dependencies` and nothing else; `copilot-proxy status` says `not running on port 4141`; `ps` shows one or more wedged `bun add @jeffreycao/copilot-api@1.13.14 --no-summary`; every retry adds ANOTHER stuck pair and none ever binds the port; `curl` to the npm registry works fine so it does not look like a network fault
**First seen**: 2026-07
**Affects**: bun 1.3.x (`bunx`) + `@jeffreycao/copilot-api` (any pinned version) on a host with a socks proxy exported as `ALL_PROXY` (Clash/mihomo, `socks://127.0.0.1:7890`)
**Status**: workaround documented; `copilot-proxy doctor` detects it; permanent fix in `copilot-proxy start` not yet wired up

## Symptom

`copilot-proxy start` prints its banner, backgrounds the job, then times out after ~20s:

```
❯ copilot-proxy start
copilot-proxy: starting (@jeffreycao/copilot-api@1.13.14) on port 4141 ...
[4] 39859
copilot-proxy: did not come up in time — check 'copilot-proxy logs'.
```

The log is two lines and stops there — no error, no stack, no bind:

```
❯ copilot-proxy logs
nohup: ignoring input
Resolving dependencies
```

`ps` shows the launcher and a package installer that never exits. Retrying stacks
them up — this is five processes from three `start` attempts, all still alive:

```
 8926  bunx @jeffreycao/copilot-api@1.13.14 start --port 4141
 8931  …/bun/1.3.8/bin/bun add @jeffreycao/copilot-api@1.13.14 --no-summary
10427  bunx @jeffreycao/copilot-api@1.13.14 start --port 4141
10434  …/bun/1.3.8/bin/bun add @jeffreycao/copilot-api@1.13.14 --no-summary
…
```

The misleading part: **the network is fine**. `curl` reaches the registry
instantly, both through the proxy and directly, so every obvious check passes:

```
registry.npmmirror.com HTTP 200 in 0.371359s     # via $HTTPS_PROXY
registry.npmmirror.com HTTP 200 in 0.182431s     # --noproxy '*'
```

Auth is fine too (`github_token` present, `doctor` shows the token file and
reaches `api.githubcopilot.com`). Nothing points at the installer.

## Root cause

`copilot-proxy start` runs the proxy via `bunx`, which must **install** the pinned
package into a temp dir (`/tmp/bunx-<uid>-@jeffreycao/…`) before `copilot-api start`
can bind the port. That install is a `bun add`, and **bun stalls resolving
dependencies through a socks `ALL_PROXY`** — indefinitely, with no error and no
timeout. `curl` through the same proxy works, which is exactly why this reads as a
non-network problem.

Two things turn one stall into a permanent wedge:

1. The wedged `bun add` **keeps bun's global install-cache lock**
   (`~/.bun/install/cache/.tmp`), so the *next* `copilot-proxy start` blocks on the
   lock and hangs the same way — even if the proxy stall would have cleared.
2. `start`'s 20s timeout returns, but **never kills the process it spawned**. Each
   retry leaves another zombie pair behind, so the situation gets monotonically
   worse the more you retry.

Proof it is the proxy env and not the registry: with the proxy vars stripped, the
identical `bunx` command resolves 99 packages and binds the port in 3 seconds.

```
Resolving dependencies
Resolved, downloaded and extracted [99]
Saved lockfile
➜ Listening on: http://localhost:4141/
```

Note the registry here is **npmmirror** (`~/.bunfig.toml` → `registry =
"https://registry.npmmirror.com"`, set for GFW speed). It is a domestic mirror, so
routing it through the proxy buys nothing and is what breaks bun.

## Workaround

Copy-pasteable. Step 1 clears the wedge, step 2 avoids re-creating it:

```bash
# 1. kill the wedged installers and release bun's global cache lock
pkill -f 'bun add.*copilot-api'
rm -rf /tmp/bunx-*-@jeffreycao "$HOME/.bun/install/cache/.tmp"/*

# 2. start with the proxy env stripped — bun resolves against npmmirror (domestic),
#    which needs no proxy; the copilot-api server itself still reaches GitHub direct
env -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
    -u HTTPS_PROXY -u https_proxy \
    copilot-proxy start
```

Step 2 is safe **on a host where GitHub Copilot is reachable without the proxy** —
verify with `copilot-proxy doctor`, whose Upstream section probes
`api.githubcopilot.com` with `--noproxy '*'`; a `direct HTTP 400` line means reached
(an unauthenticated probe is *expected* to be rejected). On a host where GitHub is
only reachable *through* the proxy, do NOT strip the env for the server — strip it
only for a warm-up `bun add`, then start normally against the now-warm cache.

## Prevention

`copilot-proxy doctor` detects this directly. Its Proxy section flags any live
`bun add … copilot-api` — red when nothing is listening (that IS the fault), yellow
when the proxy is up (a leftover that still holds the cache lock and will hang the
next restart), and prints the clear-and-restart one-liner:

```
Proxy
  ✗ listening        nothing answering on port 4141
                     → copilot-proxy start
  ✗ stale installer  3 wedged 'bun add … copilot-api' proc(s) — start is blocked at "Resolving dependencies", never binds port 4141
                     → pkill -f 'bun add.*copilot-api'; rm -rf "$HOME/.bun/install/cache/.tmp"/*; copilot-proxy start
                     → re-hangs? bun is stalling on the socks proxy — env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY copilot-proxy start
```

**Clearing the lock alone is not durable** — the stall recurs on the next cold
resolve, which is why the doctor's second hint (strip the proxy env) is the one that
actually sticks. The permanent fix is to stop `bunx` from resolving through the
socks proxy at all: either pre-install the package once and invoke the binary
directly, or have `copilot-proxy start` run a proxy-stripped warm-up `bun add`
before launching the server with the full env. Not wired up yet.

Do not "fix" this by raising `start`'s 20s timeout — the installer is wedged, not
slow; a longer wait just wedges for longer.

## Related

- [`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md) — `copilot-proxy doctor` section documents the stale-installer check
- [`dot_config/shell/43_copilot_proxy.sh`](../dot_config/shell/43_copilot_proxy.sh) — `_copilot_stale_installers` + the doctor Proxy section
- [`copilot-api-caches-degraded-model-list-at-startup.md`](copilot-api-caches-degraded-model-list-at-startup.md) — sibling copilot-api trap; also a startup-time fetch that fails in a way that looks like something else
