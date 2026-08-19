# OpenAI models via `copilot-proxy` sit at `0 tok` for minutes, then need Esc + "continue"

**Symptoms** (grep this section):
- Claude Code on a `gpt-*` / `gemini-*` model through the proxy shows no output
  at all for minutes — FleetView / the Task line reads `gpt-5.6-sol[1m] · 0 tok`
  while the timer keeps climbing
- Nothing wrong appears anywhere: `copilot-proxy status` is healthy,
  `copilot-proxy logs` shows `--> POST /v1/messages?beta=true 200`, no 4xx/5xx
- Occasionally the session never recovers and the only way out is Esc
  (`[Request interrupted by user]`) followed by typing `continue`
- Sometimes it surfaces instead as
  `API Error: Connection lost mid-response. The response above may be incomplete.`
  or `API Error: Connection closed mid-response.`
- `copilot-proxy logs` has `<-- POST /v1/messages?beta=true` lines with **no**
  matching `--> POST` line (count them: `grep -c '^<-- POST'` vs `grep -c '^--> POST'`)

**First seen**: 2026-08
**Affects**: `@jeffreycao/copilot-api@2.1.0` behind
`dot_config/shell/copilot-throttle-shim.js`, any OpenAI/Gemini reasoning model;
worse on GFW hosts where the backend runs with `--proxy-env` through
Clash/mihomo, and worse again under multi-agent workloads
**Status**: mitigated locally (shim keepalive + stall watchdog, 2026-08);
upstream copilot-api still emits no `ping` events

## Symptom

Two different things wear the same face, and separating them is most of the fix.

### Not a stall: `0 tok` is a display artifact

FleetView fills an agent's token counter in only when that agent **finishes**.
Six agents sitting at `0 tok · 14m15s` while a seventh shows `104.7k tok` are
all working; the transcript proves it:

```console
$ python3 -c '...' ~/.claude/projects/<proj>/<sess>/subagents/workflows/<wf>/agent-<id>.jsonl
{'user': 80, 'attachment': 1, 'assistant': 135} 2026-08-19T03:30:16Z → 2026-08-19T03:41:46Z
usage: input_tokens=3, output_tokens=1234, cache_read_input_tokens=95439
```

Check there before blaming the proxy. (`input_tokens: 3` is also normal for this
gateway — the real prompt size lands in `cache_read_input_tokens`.)

### The real stall: a socket with nothing on it

The failure is that **nothing is transmitted at all** while an OpenAI reasoning
model thinks, so any idle timer in the path is free to reap the connection.
Measured against `:4141` with `gpt-5.6-sol`:

```console
$ bun hdr.js                      # fetch, then read the body chunk by chunk
headers at 8.11s status 200 ct text/event-stream
first body chunk at 8.12s
chunks 598 maxgap 8.28s total 32.91s
```

The response **headers** are withheld for the whole think time — copilot-api
does not open the SSE stream early — so the entire wait happens inside one
`fetch()` with zero bytes on either socket. The backend's own log agrees; note
that its `-->` duration is time-to-headers, not stream duration (a 91s request
is logged as `16s`):

```console
$ grep -aoE '[0-9]+s$' "$TMPDIR/copilot-api-4141.log" | ...
n=1395  p50=7s  p90=20s  p99=46s  max=89s
```

And a real Anthropic stream covers exactly this with periodic `ping` events,
which copilot-api never sends:

```console
events {'message_start':1, 'content_block_start':10, 'content_block_delta':1407,
        'content_block_stop':10, 'message_delta':1, 'message_stop':1}
```

No `ping`. Mid-stream is silent too — reasoning blocks are separated by
multi-second gaps (8.28s above, longer under load).

## Root cause

Three independent contributors, all of which have to be addressed:

1. **copilot-api withholds headers until the first token and emits no `ping`.**
   The client socket is silent for the model's entire think time.
2. **Queueing adds to that silence.** The shim's semaphore (`COPILOT_SHIM_MAX`,
   default 4) makes request 5+ wait with *literally* zero traffic. Six review
   agents plus a parent session exceed the cap immediately:

   ```text
   03:37:08.849Z [shim] queued POST /v1/messages (4 in-flight, 4 waiting)
   ```

   Queue time and think time stack, and both are silent.
3. **Every hop has an idle timer.** `Bun.serve({ idleTimeout: 255 })` in the
   shim (255s is Bun's ceiling), plus Clash/mihomo on the `--proxy-env` leg to
   GitHub. When one of them reaps a silent-but-healthy connection, Claude Code
   gets no error — it just waits, which is the Esc-then-`continue` symptom.

## Workaround

The shim now does two things (`dot_config/shell/copilot-throttle-shim.js`):

- **Keepalive.** For a client-requested stream that produces nothing for
  `COPILOT_SHIM_PING_AFTER_MS` (default 10000), the shim commits the
  `text/event-stream` response itself and emits SSE **comment** frames
  (`: copilot-shim keepalive\n\n`) every `COPILOT_SHIM_PING_MS` (default 15000)
  until the upstream produces bytes — covering queue time *and* think time, and
  continuing through mid-stream gaps. A comment line is discarded by every
  spec-compliant SSE parser, so it is invisible to the Anthropic and OpenAI SDKs
  and protocol-agnostic (works for `/v1/messages` and Codex's `/responses`).
- **Stall watchdog.** Each upstream attempt is bounded by
  `COPILOT_SHIM_STALL_MS` (default 240000) — of pre-header silence *and* of
  mid-stream silence. A pre-header timeout aborts and goes through the existing
  retry path (nothing but comment frames has reached the client, so re-issuing
  is transparent); a mid-stream timeout fails the response with a real error
  instead of hanging forever.

Verify after `chezmoi apply`:

```sh
copilot-proxy shim off && copilot-proxy shim on
copilot-proxy logs shim | tail -1
#   [shim] listening on :4142 -> http://localhost:4141 (max=4, retries=3,
#          backoff=500ms, ping=15000ms after 10000ms, stall=240000ms)
```

For a multi-agent workflow, also raise the concurrency cap — the keepalive stops
queued agents from *dying*, it does not make them *run*:

```sh
export COPILOT_SHIM_MAX=8        # persist in ~/.shellrc.adhoc to keep it
copilot-proxy shim off && copilot-proxy shim on
```

(the env var has to be exported, not prefixed — a `VAR=… copilot-proxy shim off`
prefix would apply to the `off` and be gone by the time `on` spawns the process).

## Prevention

- **Before debugging a "hang", check the transcript, not the UI.** A `0 tok`
  counter proves nothing; `agent-<id>.jsonl` growing with `assistant` entries
  proves the agent is alive.
- **A request/response count mismatch in the backend log is the real signal**:

  ```sh
  L="$TMPDIR/copilot-api-4141.log"; echo "$(grep -ac '^<-- POST' $L) $(grep -ac '^--> POST' $L)"
  ```

- Do **not** read the `-->` duration as "how long the stream took" — it is
  time-to-headers. Measure a stream client-side if you need the real number.
- Keep the keepalive as a **comment** frame. An Anthropic-shaped
  `event: ping` would be wrong on Codex's `/responses` path; a comment is legal
  in both.
- Keep the grace window (`COPILOT_SHIM_PING_AFTER_MS`) non-zero. Committing the
  SSE response early spends the HTTP status line, so a later non-2xx can only be
  reported as an SSE `error` event. Fast failures (`400 model_not_supported`,
  `401 IDE token expired`, the 403 burst throttle) all answer well inside the
  window and keep their true status code.
- `COPILOT_SHIM_STALL_MS` must stay comfortably above the observed p99
  time-to-headers (46s, max 89s) or healthy reasoning requests get killed.

## Related

- [`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md) —
  manager, doctor, throttle-shim guide
- [`dot_config/shell/copilot-throttle-shim.js`](../dot_config/shell/copilot-throttle-shim.js) —
  keepalive, stall watchdog, semaphore
- [`copilot-proxy-ide-token-expired-after-refresh-backoff.md`](copilot-proxy-ide-token-expired-after-refresh-backoff.md) —
  the *other* long-running-proxy failure: there the upstream answers (401), here
  it answers nothing at all
- [`copilot-api-caches-degraded-model-list-at-startup.md`](copilot-api-caches-degraded-model-list-at-startup.md) —
  why the model list can contain no `claude-*` ids, which is what pushes this
  host onto OpenAI models in the first place
- [`backlog/copilot-proxy-supervisor.md`](../backlog/copilot-proxy-supervisor.md) —
  process supervision; again insufficient, the process never dies here
