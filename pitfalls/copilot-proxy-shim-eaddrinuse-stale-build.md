# `copilot-proxy: shim did not come up` + a wall of `GET /_shim/health 404` in the proxy log

**Symptoms** (grep this section):
- A managed launcher refuses to run:
  ```
  copilot-proxy: shim did not come up — check /var/folders/.../copilot-shim-4142.log
  copilot-proxy: managed client refused to bypass the enabled metrics shim.
    use 'copilot-proxy shim off' only for an intentional direct-mode escape.
  ```
- `copilot-proxy status` reports the contradiction plainly:
  `shim:   ON but DOWN (managed clients fail closed; try 'copilot-proxy shim on')`
  — and `copilot-proxy shim on` changes nothing, because it was already on.
- `copilot-proxy logs` (the **proxy's** log, port 4141) is flooded with the
  health probe it should never have seen:
  ```
  <-- GET /_shim/health
  --> GET /_shim/health 404 0ms
  ```
- The shim's own log has the real story:
  ```
  error: Failed to start server. Is port 4142 in use?
   syscall: "listen",  code: "EADDRINUSE"
  ```

**First seen**: 2026-08-26
**Affects**: `dot_config/shell/43_copilot_proxy.sh` any time an older build of
`copilot-throttle-shim.js` is still resident on `$COPILOT_SHIM_PORT`
**Status**: fixed 2026-08-26 — `_copilot_shim_start` reclaims the port

## Root cause

Liveness and startup disagreed about what "the shim is running" means.

`_copilot_shim_alive` probes `/_shim/health` **on purpose** — a plain TCP
connect would happily accept "an arbitrary process, or an older passthrough
build" as a healthy metrics shim. But an older build doesn't serve
`/_shim/health` at all: it treats the path as an ordinary request and **forwards
it upstream**, so :4141 answers `404`, `curl -f` fails, and the probe correctly
reports *not alive*.

`_copilot_shim_start` then took "not alive" to mean "port free" and spawned a
new shim, which died instantly with `EADDRINUSE`. Ten one-second retries later
it gave up — and, since `nohup … &` detaches, nothing in the terminal connected
the failure to the log file until you went and read it.

The result is a stable wedge, not a flake:

```
old shim on :4142  →  /_shim/health proxied upstream  →  4141 answers 404
                   →  _copilot_shim_alive == false
                   →  _copilot_shim_start spawns  →  EADDRINUSE  →  dies
                   →  _copilot_require_shim fails closed  →  no client can run
```

The 404 flood in the proxy log is the fingerprint: it proves *something* on 4142
is proxying, i.e. the port is occupied by a shim that is running but too old to
answer the probe. A port that were genuinely free produces no upstream traffic
at all.

## Fix

Before spawning, `_copilot_shim_start` inspects the port (`lsof -tiTCP -sTCP:LISTEN`):

- listener's `ps` command line matches `copilot-throttle-shim.js` → it's ours,
  stale or old-build: `kill` it, wait up to 5s for the socket to release, spawn.
- anything else → print the PID and command name and return 1. Killing an
  unrelated process on a well-known port is not this function's call.

The failure path also tails 5 lines of the shim log inline, so `EADDRINUSE`
lands in the terminal instead of only in a file nobody opens.

## Manual recovery on an unpatched host

```console
$ copilot-proxy shim off && copilot-proxy stop   # stop also pkills the shim
$ pkill -f copilot-throttle-shim.js              # belt and braces
$ copilot-proxy shim on && copilot-proxy start
```

## Generalisable

**A liveness probe strict enough to reject an old build must be paired with a
start path that can reclaim the port from one.** Whenever "is it healthy?" is
narrower than "is the port taken?", the gap between the two answers is a wedge:
the supervisor concludes *dead* and the OS concludes *occupied*, and they never
converge on their own. Either widen the probe (and lose the version check) or
teach the starter to look at the port directly — never let it infer port state
from health state.

## See also

- [`copilot-proxy-openai-model-silent-stall.md`](copilot-proxy-openai-model-silent-stall.md) — why the shim exists (SSE keepalive + stall watchdog)
- [`copilot-proxy-stale-package-lock-integrity.md`](copilot-proxy-stale-package-lock-integrity.md) — the other half of the same broken session
