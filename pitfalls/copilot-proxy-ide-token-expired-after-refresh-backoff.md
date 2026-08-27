# `copilot-proxy` stays up but every request returns `401 IDE token expired`

**Symptoms** (grep this section):
- `copilot-proxy doctor --live` reports
  `✗ round-trip claude-haiku-4-5 → HTTP 401`
- `copilot-proxy logs` repeatedly shows
  `ERROR HTTP error: IDE token expired: unauthorized: token expired` and
  `--> POST /v1/messages?beta=true 401`
- The process is still listening, `/v1/models` still returns the cached model
  list, and unauthenticated reachability probes still get HTTP 400/401
- Earlier log lines show `ERROR Failed to refresh Copilot token`, followed by
  `Retrying Copilot token refresh in ...s`; the delay can grow to 600 seconds
- A plain `copilot-proxy restart` immediately restores HTTP 200 without another
  device login

**First seen**: 2026-07
**Affects**: `@jeffreycao/copilot-api@1.13.14` on a long-running proxy when
GitHub's `copilot_internal/v2/token` exchange is intermittently unreachable;
observed on macOS behind Clash/mihomo, but the failure mode is not OS-specific
**Status**: upstream refresh loop exists but can leave an expired token active
during long retry backoff; immediate workaround documented, reactive local
self-heal not yet implemented

## Symptom

The proxy looks structurally healthy: both the backend and throttle shim are
listening, the cached model list contains Claude models, and all GitHub hosts are
network-reachable. Only a real inference request fails:

```text
Live probe
  ✗ round-trip       claude-haiku-4-5 → HTTP 401 in 1.077504s
```

The backend log contains the distinctive upstream response:

```text
ERROR  Failed to create messages Response { status: 401,
  statusText: 'Unauthorized',
  ... }

ERROR  HTTP error: IDE token expired: unauthorized: token expired

--> POST /v1/messages?beta=true 401 1s
```

This is easy to misdiagnose as a missing token file, an expired long-lived
GitHub device-login token, or a dead local process. None was true in the observed
case. `~/.local/share/copilot-api/github_token` existed, the process answered,
and restarting it successfully exchanged the same stored credential.

## Root cause

There are two token layers:

1. `copilot-proxy auth` stores a relatively long-lived GitHub `ghu_` credential
   in `~/.local/share/copilot-api/github_token`.
2. `copilot-api` exchanges that credential at
   `https://api.github.com/copilot_internal/v2/token` for a short-lived Copilot
   IDE token used against `api.enterprise.githubcopilot.com` or
   `api.githubcopilot.com`.

The fork already has a refresh loop; this is **not** simply a missing refresh
feature. In `@jeffreycao/copilot-api@1.13.14`, `setupCopilotToken()` starts
`runCopilotRefreshLoop(refresh_in, ...)`, which refreshes one minute early. When
the exchange fails it retries with exponential backoff plus jitter, capped at
600 seconds, while retaining the old token in memory.

The failed session's rotated log showed all three exchange failure shapes:

```text
ERROR  Failed to refresh Copilot token: fetch failed
[cause]: getaddrinfo ENOTFOUND api.github.com
WARN  Retrying Copilot token refresh in 23s

ERROR  Failed to refresh Copilot token: fetch failed
[cause]: Connect Timeout Error (attempted address: api.github.com:443, timeout: 10000ms)

ERROR  Failed to get Copilot token response body <!DOCTYPE html>
...
ERROR  Failed to refresh Copilot token: Failed to get Copilot token
WARN  Retrying Copilot token refresh in 600s
```

Once the in-memory IDE token expires, inference requests return 401 until one of
those scheduled exchanges succeeds. The server stays alive and `/v1/models`
continues serving its cache, so a process-only health check considers it healthy.

This also explains why two `doctor` sections can look contradictory:

- `Upstream` accepts an unauthenticated HTTP 400/401 as proof of network
  reachability only; it does **not** prove token exchange works.
- `Models · upstream could not query GitHub directly` means the authenticated
  exchange/model query failed, even though `bun`, `jq`, and the token file are
  present.

## Workaround

Restart the backend and shim through the existing manager. Startup performs an
immediate token exchange and resets the refresh-loop backoff:

```sh
copilot-proxy restart
copilot-proxy doctor --live
```

A healthy result ends with:

```text
Live probe
  ✓ round-trip       claude-haiku-4-5 → HTTP 200

all checks passed
```

Only re-authenticate if restart still returns 401 or startup cannot exchange the
stored GitHub credential:

```sh
copilot-proxy auth
copilot-proxy restart
copilot-proxy doctor --live
```

Do not start with `auth`: in the observed case the stored `ghu_` credential was
valid, and a restart alone recovered it.

## Prevention

- When this exact 401 appears, inspect earlier logs for
  `Failed to refresh Copilot token` before blaming the token file or Copilot
  entitlement.
- `launchd KeepAlive` / systemd `Restart=always` alone cannot catch this case:
  the process never exits. The existing supervisor backlog is useful for crashes
  and login-start, not logical auth health.
- The safest future local self-heal is reactive, not periodic: have the throttle
  shim detect a `401` whose small response body contains `IDE token expired`,
  single-flight a **backend-only** restart, wait for port 4141 to become healthy,
  and replay the buffered request once. Add a lock/cooldown to prevent concurrent
  401s from causing a restart storm. Do not restart the shim that is holding the
  client request.
- Avoid periodic live inference probes: they consume quota. Periodic blind
  restarts can also interrupt a valid long-running stream.
- The shim retries `403/429/500/502/503/504`; adding bare 401 to that set would
  just resend the same expired token and is not a fix.

This is not being graduated to an `AGENTS.md` hard invariant yet: it does not
silently corrupt state, and the workaround is a single manager command.

## Related

- [`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md) —
  manager, doctor, authentication, and throttle-shim guide
- [`dot_config/shell/43_copilot_proxy.sh`](../dot_config/shell/43_copilot_proxy.sh) —
  `restart`, `doctor --live`, and authenticated upstream checks
- [`dot_config/shell/copilot-throttle-shim.js`](../dot_config/shell/copilot-throttle-shim.js) —
  current retry statuses and the natural integration point for reactive healing
- [`backlog/copilot-proxy-supervisor.md`](../backlog/copilot-proxy-supervisor.md) —
  process-supervisor analysis; explicitly insufficient for logical 401 failures
- [`copilot-api-caches-degraded-model-list-at-startup.md`](copilot-api-caches-degraded-model-list-at-startup.md) —
  sibling case where the process remains healthy while cached upstream state is bad
