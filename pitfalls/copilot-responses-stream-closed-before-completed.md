# Codex repeatedly reports "stream closed before response.completed"

**Symptoms** (grep this section): `■ stream disconnected before completion: stream closed before response.completed`; repeated `continue` fails the same way; `POST /responses` is HTTP 200 but has `stream_ms=0`; fork log shows `ERROR WebSocket error: ErrorEvent { type: 'error'` / `TLSSocket.onSocketClose`; shim stats incorrectly show `error_kind=null`
**First seen**: 2026-09
**Affects**: Codex CLI 0.151.0 through `@jeffreycao/copilot-api@2.3.4`, with `useResponsesApiWebSocket: true`; observed on macOS arm64 behind Clash HTTP proxy
**Status**: workaround verified (`useResponsesApiWebSocket=false`); shim observability fixed with Responses terminal-event validation

## Symptom

An otherwise healthy Codex session stops after ordinary tool work. Repeating
`continue` only produces the same terminal error:

```text
■ stream disconnected before completion: stream closed before response.completed
```

The HTTP layer looks successful. The two requests correlated to one incident
both queued for only 1ms, received HTTP 200 headers, then reached EOF without a
measurable stream body:

```text
local_t             endpoint    status  q_ms  h_ms    s_ms  error_kind
2026-09-02 00:11:16 /responses  200     1     285     0     null
2026-09-02 00:11:16 /responses  200     1     1064    0     null
```

At the same point, the fork log contains the evidence hidden from the shim:

```text
ERROR  WebSocket error: ErrorEvent { type: 'error', ... }
    at #onSocketClose (.../undici/lib/web/websocket/websocket.js:609:16)
    at TLSSocket.onSocketClose (.../undici/lib/web/websocket/websocket.js:95:45)
```

This is distinct from a queue stall: the failing requests were admitted in
1ms. A high adaptive limit (`active=6/16`) increased concurrent WebSocket
pressure in the first incident, but reducing the limit alone did not repair the
transport.

## Root cause

The fork configuration had `useResponsesApiWebSocket: true`. When its upstream
Responses WebSocket closed, the fork had already returned HTTP 200 and then
ended the downstream SSE without any of the required terminal events:
`response.completed`, `response.failed`, or `response.incomplete`.

The fork's own documentation states that WebSocket failures are not
automatically retried over HTTP. The shim used to treat any clean reader EOF as
a successful request, so its metrics recorded `200 / error_kind=null` even
though Codex correctly rejected the incomplete protocol stream.

Do not diagnose this error string from the string alone. A deterministic
payload rejection can present identically; correlate the 0ms stream row with
the fork's `WebSocket error` before applying the transport workaround.

## Workaround

The fork owns its live configuration under its data directory; this file is not
chezmoi-managed. Disable the Responses WebSocket transport and restart:

```diff
-  "useResponsesApiWebSocket": true,
+  "useResponsesApiWebSocket": false,
```

```sh
jq '.useResponsesApiWebSocket' \
  "${XDG_DATA_HOME:-$HOME/.local/share}/copilot-api/config.json"
copilot-proxy restart
copilot-proxy limiter reset
```

Start/restart from a persistent interactive shell. A short-lived automation
shell can reap its background fork after reporting startup success, leaving the
shim alive on 4142 but producing an unrelated follow-on error:

```text
unexpected status 502 Bad Gateway: shim: upstream unreachable: Error: Unable to connect. Is the computer able to access the url?
```

The verified A/B ran the previously failing pane through a 3m51s `continue`,
multiple `/responses` turns, checks, commit, fast-forward, and push. No new
WebSocket error or premature terminal EOF appeared.

## Prevention

- Keep the adaptive limiter at its startup range (`4..8`) unless a measured
  workload justifies a different ceiling; `copilot-proxy limiter reset` is a
  safe live correction and does not cancel active requests.
- Search fork and shim logs together. `status=200` is insufficient evidence of
  a valid SSE response.
- The shim now records an EOF before a Responses terminal event as
  `upstream_protocol_eof` and logs `ended before a Responses terminal event`.
  It does not fabricate `response.completed`.
- Treat `useResponsesApiWebSocket=false` as a host/network workaround, not a
  universal invariant; re-test after an audited fork upgrade before restoring
  WebSocket.

## Related

- [`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md)
- [`copilot-proxy-openai-model-silent-stall.md`](copilot-proxy-openai-model-silent-stall.md)
- [copilot-api Responses transport documentation](https://github.com/caozhiyuan/copilot-api/blob/dev/README.md)
- [copilot-api issue #307](https://github.com/caozhiyuan/copilot-api/issues/307) — same client symptom from a different, deterministic payload failure
