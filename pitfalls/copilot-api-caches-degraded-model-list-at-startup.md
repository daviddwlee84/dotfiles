# copilot-api caches a degraded model list at startup → every Claude request 400s

**Symptoms** (grep this section):
- Claude Code against the Copilot proxy dies instantly with
  `API Error: 400 {"error":{"message":"The requested model is not supported.","code":"model_not_supported","param":"model","type":"invalid_request_error"}}`
- `copilot-proxy logs` shows `ERROR HTTP error: { error: { ... code: 'model_not_supported' ... } }`
  and `--> POST /v1/messages?beta=true 400`
- The startup banner lists **no `claude-*` ids** — only `gpt-*`, `gemini-*`,
  `text-embedding-*`
- `ℹ Models refresh: 13 new` instead of the usual `21 new`
- It worked yesterday, nothing changed in settings, and `copilot-proxy status`
  reports `RUNNING`
- Restarting the proxy fixes it completely, with no other change

**First seen**: 2026-07
**Affects**: `@jeffreycao/copilot-api` (and the original `copilot-api`), any
network path that can degrade a single request — VPN, Clash/mihomo, captive
portal, corporate MITM proxy
**Status**: upstream behaviour (fetch-once cache); mitigated locally by
`copilot-proxy doctor` + `copilot-proxy restart`

## Symptom

`copilot-api` fetches the model catalogue from
`https://api.enterprise.githubcopilot.com/models` exactly **once, at process
start**, and caches it for the lifetime of the process. There is no periodic
refresh and no refresh on a cache miss.

If that single startup request is served a truncated response — a flaky Clash
node, a VPN reconnect, GitHub briefly returning a reduced set — the proxy
happily comes up with whatever it got. Every subsequent request for a model
that isn't in the cached list is rejected upstream with a `400
model_not_supported`, forever, until the process is restarted.

Two consecutive runs of the *same binary*, *same token*, *same account*, minutes
apart:

```
# poisoned run
ℹ Fetching models from https://api.enterprise.githubcopilot.com/models
ℹ Models refresh: 13 new
ℹ Available models:
- gemini-3.1-pro-preview
- gpt-5.5
- text-embedding-ada-002
  ...                       ← not one claude id

# healthy run, after `copilot-proxy restart`
ℹ Models refresh: 21 new
ℹ Available models:
- claude-opus-4-8
- claude-sonnet-5
  ...
```

## Root cause

The cache is populated once and is never invalidated. Worse, the failure is
**silent**: a truncated `/models` response is a valid `200` with a shorter
`data` array, so `copilot-api` has nothing to complain about. It logs
`Models refresh: N new` and proceeds.

The resulting 400 is emitted by *GitHub*, not by the proxy — the response
carries an `x-github-request-id` — so the error is indistinguishable from the
legitimate case where an organisation's Copilot policy genuinely disables
Anthropic models. That is what makes this expensive to debug: the logs point at
an entitlement problem, the actual problem is a stale cache, and the fix
(restart) is unrelated to anything the error message mentions.

## Diagnosis

`copilot-proxy doctor` exists for exactly this. It fetches the model list from
GitHub live (exchanging the stored `ghu_` token for a Copilot bearer, both
passed to `curl` via `-K -` so neither lands in `ps` output) and diffs it
against what the running proxy serves:

```
Models
  ✓ served           13 model ids
  ✗ claude models    0 of 13 — the proxy is serving no Anthropic models
  ✓ upstream         36 ids from GitHub, 8 claude
  ✗ STALE CACHE      upstream serves claude ids the proxy does not:
                     → claude-opus-4-8
                     → claude-sonnet-5
                     → copilot-api caches /models at STARTUP — a flaky fetch poisons the session
                     → copilot-proxy restart   # re-fetch the list
```

The two cases it separates:

| Proxy serves claude? | Upstream serves claude? | Cause | Fix |
|---|---|---|---|
| no | **yes** | stale cache from a degraded startup fetch | `copilot-proxy restart` |
| no | no | org Copilot policy disables Anthropic | restarting will **not** help; ask your admin |

## Workaround

```bash
copilot-proxy doctor     # confirm it is the cache, not entitlement
copilot-proxy restart    # re-fetch /models
```

Then check the banner says `Models refresh: 21 new` (or whatever your account's
full count is), not `13 new`.

### Prevention

- Run `copilot-proxy doctor` before a long session, especially right after
  connecting/reconnecting a VPN or switching a Clash node. It is read-only and
  costs no quota.
- Start the proxy *after* the network is settled, not from a login hook that
  races with the VPN coming up.
- Do not diagnose `model_not_supported` from the error text alone. It does not
  distinguish the two causes above, and neither does `copilot-proxy status`
  (which only greps the *cached* list for claude ids — a poisoned proxy honestly
  reports "no claude models" without saying why).

### What does NOT work

- Re-pinning the model with `copilot-model` — the id is fine, the cache is not.
  `copilot-model` validates against the same poisoned `/v1/models`, so it will
  also refuse the correct id.
- Re-authenticating (`copilot-proxy auth`). The token is valid; the exchange
  works; the cache is still stale.
- Waiting. There is no TTL.

## Related

- [`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md) — the guide, incl. `copilot-proxy doctor`
- [`dot_config/shell/43_copilot_proxy.sh`](../dot_config/shell/43_copilot_proxy.sh) — `doctor`, `_copilot_upstream_models`
- Dotted vs hyphenated model ids (`claude-opus-4.8` vs `claude-opus-4-8`) and the
  `[1m]` suffix are a *separate* trap — see the guide's "Dotted ids cause the
  '[Opus 4] retired' warning" section. `doctor` normalises both when comparing.
