# Codex on Astra reports remote compact 408, then later says Context compacted

**Symptoms**: `Error running remote compact task`; `shim: upstream returned 408`;
`Timed out reading request body. Try again, or use a smaller request size.`;
`user_request_timeout`; a later `Context compacted` and `Context 98% left`
**First seen**: 2026-09
**Affects**: Codex CLI 0.153.4, copilot-api 2.3.4, gpt-6-astra through copilot-proxy
**Status**: intermittent failure documented; later compaction verified; no timeout change

## Symptom

The user observed both ordinary inference and remote compaction fail:

```text
■ Error running remote compact task: shim: upstream returned 408: {"error":{"message":"{\"error\":{\"message\":\"Timed out reading request body. Try again, or use a smaller request size.\",\"code\":\"user_request_timeout\"}}\n","type":"error"}}
■ shim: upstream returned 408: {"error":{"message":"{\"error\":{\"message\":\"Timed out reading request body. Try again, or use a smaller request size.\",\"code\":\"user_request_timeout\"}}\n","type":"error"}}
```

After the prompt was submitted again, the UI showed `Context compacted`,
continued the requested work, and ended with `Context 98% left`. This is not
evidence that every failed attempt was recovered by a transparent shim retry.

## Evidence

The matching Codex rollout in the dotfiles-iSH project records
`model_provider=copilot_api`, model `gpt-6-astra`, and effort `xhigh`.
It contains a `compacted` record at **2026-09-08 03:09:01.733 UTC**
(11:09:01 Asia/Shanghai), with five replacement-history items. This confirms
that a later compaction completed; Astra compaction is not categorically
unsupported. The screenshot supplies the failed compact error text; the
rollout does not preserve those errors as separate error events.

Around this interval the shim logged repeated `POST /responses -> 408`,
including failures after its one allowed request-body-timeout replay.
The shim metrics do not label compaction or retain request contents, so
individual failed requests cannot be matched to this compact task by timing
alone. Do not label every nearby 408 or 499 as this session's compaction.

## Root cause and timeout ownership

These failures require different remedies:

| Evidence | Owner / meaning | Does a longer shim watchdog help? |
|---|---|---|
| HTTP 408 with `user_request_timeout` and `Timed out reading request body` | The remote service returned a completed error response because it did not finish reading the body in time | No: the failed attempt has already ended |
| `upstream sent no response headers in 240000ms` | The shim aborted an attempt that produced no headers | Possibly, if the remote operation is still progressing and other deadlines allow it |
| `upstream_stall` after HTTP 200 | The shim's upstream stream-inactivity watchdog fired; 200 alone did not prove completion | Only after distinguishing a slow operation from a broken stream |
| 499 / `client_cancel` | The downstream client disconnected or canceled | No proof of a timeout without client-side evidence; a manual interrupt also produces it |

The body-read 408 does not identify the failing hop: large serialized inputs,
intermittent upload/proxy connections, and the remote receiver remain possible
contributors. A later success supports an intermittent failure, not a measured
network-speed diagnosis. Nested JSON in the error is wrapping, not another
independent timeout.

## Deadline coordination

The inspected settings were:

- Shim `COPILOT_SHIM_STALL_MS=240000`: per-attempt pre-header silence and
  upstream stream inactivity.
- Fork `responsesTransport.headersTimeoutMsV2=300000` and
  `streamInactivityTimeoutMs=300000`.
- Codex provider `stream_idle_timeout_ms=300000`: an SSE idle timeout,
  **not a proven five-minute total request deadline**.
- The separate Claude incident showed cancellation at about 300 seconds;
  do not transfer that observed total budget to Codex without verification.

For a client with a known total deadline, budget the entire operation:

```text
queue + sum(attempt durations) + sum(backoffs) + error/response margin
    < client total deadline
```

A per-attempt timeout below the client deadline is insufficient when retries
consume the remainder. For example, a 240s first attempt inside a 300s total
budget leaves less than 60s for its retry. If extending a genuinely slow
compact operation, coordinate the fork, shim, and actual client deadline;
stop starting retries when insufficient budget remains, propagate client
cancellation, and retain a finite watchdog. These are design requirements,
not new behavior implemented by this documentation change.

SSE comment keepalives can protect a downstream idle timer that counts raw
bytes; client behavior must be verified. They do not extend an absolute
deadline or the remote server's request-body-read deadline, and are not a
solution for non-streaming requests.

## Workaround and prevention

- Keep the original session. Verify a `compacted` record or reduced context
  after a later success before assuming the compact is still failing.
- Compact earlier to reduce serialized input size. If this error persists,
  compare a smaller request or a different proxy egress with the same model.
- Keep the existing bounded 408 replay. Adding long waits or many identical
  retries can multiply latency without repairing the remote body-read limit.
- Change timeout values only for observed shim/fork watchdog failures, using
  the client's real deadline semantics and an end-to-end budget.

No proxy timers or retry policy were changed for this incident.

## Related

- [Claude/Astra stalls near the auto-compact threshold](claude-astra-auto-compact-retries-at-83-percent.md)
- [Request-body 408 and context-policy errors](copilot-proxy-context-policy-and-request-body-errors.md)
- [Silent socket watchdogs](copilot-proxy-openai-model-silent-stall.md)
