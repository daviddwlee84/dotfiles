# Claude on Astra retries at 83% context and never finishes compaction

**Symptoms**: `0% until auto-compact`; `Request timed out.`;
`upstream sent no response headers in 240000ms`; `Context 83% (834k/1.0M)`
**First seen**: 2026-09
**Affects**: Claude Code 2.1.261, copilot-api 2.3.4, gpt-6-astra
**Status**: timeout sequence diagnosed; large-session recovery not yet verified

## Symptom

The session reached approximately 834k input tokens and kept retrying. Its
transcript contained no successful `compact_boundary`. Other requests still
returned HTTP 200. The pane showed:

```text
Request timed out. · Retrying in 2s · attempt 3/10
0% until auto-compact
Context 83% (834k/1.0M)
```

## Root cause and evidence limits

The live model catalog advertised a 1,000,000-token context, but an
872,000-token input ceiling. Both the project pin and the running Claude
process had `CLAUDE_CODE_AUTO_COMPACT_WINDOW=872000`. A roughly 95% trigger
is about 828k, so the 83% HUD reading does not mean compaction is premature.

The last successful parent response used 833,762 input tokens. At the compact
boundary, timing records showed a streamed request ending with
`error_kind=upstream_stall` after 289s, followed by non-streamed attempts at
14:47:29, 14:52:30, and 14:57:31 UTC. Each lasted approximately 300s and ended
as 499/client_cancel. The shim aborted pre-header silence at 240s and retried,
leaving only about a minute before the client canceled. Queue times were
31–43ms. This explains the retry loop, not why the remote response stalled.

Request contents are not recorded by the shim, so the association of these
requests with the parent's compaction is based on timing, pane state, and
transcript progress. It is not a payload-level correlation.

A synthetic request using the fork's recognized compaction system prompt,
the same Astra model, and a tiny conversation succeeded through `/v1/messages`
in 6.57s with summary text. Thus the compact translation path works on small
inputs; this does not prove 834k-token compaction can finish within its budgets.

## Recovery options

Stop the repeated attempt before changing the session. A supported model with
sufficient live input capacity can be used temporarily for `/compact`, then
switch back to Astra. Retain the original transcript. A smaller-context model
must not be selected for an already oversized input.

For later sessions, compact earlier. Merely increasing one timeout is not a
complete fix: Claude's request deadline, the shim's pre-header and stream
watchdogs, and the fork's Responses deadlines all participate. SSE keepalive
protects the downstream stream, not non-streaming requests or the upstream leg.

No timers, model selection, or inputs were changed in the affected running pane
during this diagnosis. Large-session recovery still requires verification.

## Related

- [Context policy and body timeouts](copilot-proxy-context-policy-and-request-body-errors.md)
- [Silent stream stalls](copilot-proxy-openai-model-silent-stall.md)
- [Codex/Astra remote compact 408 followed by success](codex-astra-remote-compact-408-then-succeeds.md) — a separate incident; an upstream body-read 408 is different from this shim/client timeout sequence.
