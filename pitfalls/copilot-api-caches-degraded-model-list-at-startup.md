# copilot-api caches a degraded / geo-filtered model list at startup → every Claude request 400s

**Symptoms** (grep this section):
- Claude Code against the Copilot proxy dies instantly with
  `API Error: 400 {"error":{"message":"The requested model is not supported.","code":"model_not_supported",...}}`
- Startup banner lists **no `claude-*` ids** — only `gpt-*`, `gemini-*`, embeddings
- `curl` through Clash/Verge still sees Claude in `/models`, but the running
  `copilot-api` process does not
- OpenCode's GitHub Copilot provider shows the same Claude-less list
- It "used to work" under Clash for Windows **TUN / Mixin** (all TCP captured),
  and broke after switching to System Proxy only (Clash Verge without TUN)

**First seen**: 2026-07
**Affects**: `@jeffreycao/copilot-api`, OpenCode native GitHub Copilot, any Node
  client that ignores the macOS System Proxy on a GFW host
**Status**: upstream geo-filters Anthropic models by egress; mitigated locally by
  `COPILOT_HTTP_PROXY=auto` → `--proxy-env` + `HTTPS_PROXY` on start, plus
  `copilot-proxy doctor` direct-vs-via-proxy A/B

## Root causes (two look identical)

### A. Egress geo-filter (most common after leaving TUN)

Same token, same enterprise account:

| Path | Claude count |
|---|---:|
| Direct / CN egress (`curl --noproxy '*'`) | 0 |
| Via overseas Clash node (e.g. SG VLESS) | 8 |

Node/`copilot-api`/`OpenCode` do **not** read macOS System Proxy. With only
System Proxy on (no TUN), they fetch the direct catalog and cache 0 Claude for
the process lifetime. `curl` still shows Claude because it honors System Proxy —
which is why `doctor` used to mis-label this as "org entitlement".

### B. Flaky node / truncated response

A single degraded Clash hop during the one-shot `/models` fetch caches a short
list. Restart after the node is healthy.

## Fix

```bash
proxy-status                 # should show Verge/mihomo port (e.g. 7897)
copilot-proxy restart        # auto attaches --proxy-env when a local proxy is up
copilot-proxy doctor         # expect: upstream via proxy has claude; served has claude

# non-GFW machine / force direct:
COPILOT_HTTP_PROXY=never copilot-proxy restart

# force a port:
COPILOT_HTTP_PROXY=http://127.0.0.1:7897 copilot-proxy restart
```

OpenCode: launch with `HTTPS_PROXY=http://127.0.0.1:7897` (or enable TUN).

## Related

- Shell: `~/.config/shell/43_copilot_proxy.sh`, `50_networking.sh` (`proxy-status`)
- Docs: `docs/tools/copilot-claude-proxy.md`
