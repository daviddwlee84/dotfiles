# Claude Code through copilot-proxy returns context-window 400, cyber_policy 422, or request-body 408

**Symptoms** (grep this section): `Your input exceeds the context window of this model`; `code":"cyber_policy"`; `Timed out reading request body. Try again, or use a smaller request size.`; `code":"user_request_timeout"`; `shim: upstream returned 408`
**First seen**: 2026-09
**Affects**: Claude Code 2.1.251 and Codex clients using copilot-api 2.3.4 through `copilot-throttle-shim.js`
**Status**: context overflow fixed locally; request-body timeout mitigated with one bounded replay; policy rejection is expected provider behavior

## Symptom

Three visually similar API failures have different owners and must not be handled as one generic retry problem:

```text
API Error: 400 {"error":{"message":"Your input exceeds the context window of this model. Please adjust your input and try again.","code":"invalid_request_body"}}
```

```text
API Error: 422 {"error":{"message":"This content was flagged for possible cybersecurity risk. If this seems wrong, try rephrasing your request. To get authorized for security work, join the Trusted Access for Cyber program: https://chatgpt.com/cyber","code":"cyber_policy"}}
```

```text
shim: upstream returned 408: {"error":{"message":"{\"error\":{\"message\":\"Timed out reading request body. Try again, or use a smaller request size.\",\"code\":\"user_request_timeout\"}}\n","type":"error"}}
```

The context error appeared after a successful Claude request at 920,329 tokens while the selected GPT model advertised a 922,000-token prompt ceiling. No `compact_boundary` existed in the transcript.

The 408s appeared on both `/v1/messages` and `/responses`, usually after roughly 60–70 seconds. Some followed retryable 500s; others were the first upstream response. The 422s were single attempts and were not retried.

## Root cause

- `[1m]` tells Claude Code that the full model context is one million tokens. It does not communicate Copilot's smaller input ceiling. Claude therefore waited until roughly 95% of 1M before auto-compacting, after the model's 922k `max_prompt_tokens` limit.
- A 408 `user_request_timeout` means the upstream did not finish reading the request body. The shim already has that body buffered, so one exact same-model replay is safe; applying the normal three-retry budget can instead turn a persistent large-body failure into several minutes of waiting.
- A 422 `cyber_policy` is an upstream content-policy decision, not a transport fault. Retrying the identical body or rewriting the response cannot make it valid and must not be used to bypass the policy.

## Workaround

For context errors, refresh the project pin and restart Claude Code so the launcher writes the live prompt ceiling:

```sh
copilot-proxy start
copilot-model --auto
copilot-here on
copilot-here status
```

For an already-overfull session, rewind several turns before running `/compact`, or start a fresh conversation. A compact request built from an already-rejected prompt may also exceed the provider limit.

For a persistent 408 after the shim's one replay, compact or clear the conversation and retry later; inspect `copilot-proxy events` and `copilot-proxy logs shim` to distinguish it from a policy response.

For a 422, rephrase a legitimate benign request to remove ambiguous cybersecurity wording. Do not retry automatically or attempt to evade the provider policy; use the provider's documented access/review path if the request is authorized security work.

## Prevention

- Claude launchers derive `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from live `max_prompt_tokens`, falling back to context minus maximum output only when necessary. `[1m]` remains a separate HUD/full-context hint.
- `copilot-throttle-shim.js` replays request-body 408 once at most, never retries policy 422, and retains the same body, model, and trace id.
- Unit fixtures cover the 408 replay and one-attempt 422 behavior. The Unix and Windows shim copies remain byte-identical.

## Follow-up: route comparison on 2026-09-22

The production backend was 2.5.2 and the selected model was `gpt-6-astra`.
Production requests of roughly 0.37 MB and 2.25 MB returned request-body 408,
while later requests of roughly 2.56 MB completed. This is not evidence of a
fixed request-size limit. Admission was available with zero unknown leases
during the comparison; another restart would not address that 408.

Tests used synthetic text, not conversation history, with bounded output and no
automatic replay. Isolated backend processes used private temporary API homes;
their credential copies and processes were removed afterwards.

| Test path | Payload bytes | Result | Seconds |
|---|---:|---|---:|
| Backend, no explicit proxy | 33,451 | completed | 10.32 |
| Backend, HTTP proxy | 33,451 | completed | 20.45 |
| Backend, HTTP proxy | 399,048 | completed | 8.70 |
| Backend, no explicit proxy | 399,048 | completed | 8.97 |
| Backend, no explicit proxy | 2,535,929 | HTTP 200, completion unconfirmed | 66.48 |
| Backend, HTTP proxy | 2,535,929 | completed | 25.00 |

Clash TUN was enabled. **No explicit HTTP proxy is not proof of direct egress.**
The second comparison therefore sent the same 399,049-byte Responses payload
directly to the authenticated Copilot endpoint with curl HTTP/1.1, first binding
the physical default-route interface (`--noproxy '*' --interface en1`), then
using the explicit HTTP proxy. It bypassed both local shim and backend.
Credentials stayed in private temporary header files and were deleted afterwards.

| Order | Route | Result | Seconds |
|---|---|---|---:|
| 1 | physical interface | response.completed | 4.91 |
| 2 | HTTP proxy | HTTP 408 user_request_timeout | 65.89 |
| 3 | HTTP proxy | response.completed | 8.09 |
| 4 | physical interface | response.completed | 6.17 |

Live controller connections showed Copilot matching `DomainKeyword/github` and
using the configured PROXY group through its Singapore Reality node. These two
pairs localize an observed failure to a request using that route, but do not
prove whether the local proxy, tunnel/node, packet loss, or upstream handling
caused it. The route is intermittent, not universally broken. Synthetic requests
also do not reproduce the complete structure of a long agent conversation.

Do not increase retries or reset admission as a claimed fix. A scoped follow-up
can compare a different node or a Copilot-specific DIRECT rule; merely clearing
HTTP proxy environment variables while TUN is active is not the same comparison.
Record terminal events, not just HTTP 200, when checking streamed responses.

Separately, an installed lazyclash with an older target schema could block
`copilot-proxy restart` before either process was stopped. Explicit service URLs
now use `--config /dev/null` for the supported lifetime-check interface. This
preserves the separate temporary-SSH registry guard while avoiding unrelated
target/profile parsing. Automatic discovery still requires valid settings.

## Related

- [Codex/Astra remote compact 408 followed by success](codex-astra-remote-compact-408-then-succeeds.md) — includes verified recovery and timeout ownership; extending the shim watchdog does not extend a remote request-body-read deadline.

- `docs/tools/copilot-claude-proxy.md`
- `tests/unit/copilot_proxy.bats`
- `tests/fixtures/copilot-shim-hardening.mjs`
- [`copilot-proxy-openai-model-silent-stall`](copilot-proxy-openai-model-silent-stall.md)
