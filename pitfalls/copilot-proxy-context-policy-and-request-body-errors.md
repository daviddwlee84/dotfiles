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

## Related

- `docs/tools/copilot-claude-proxy.md`
- `tests/unit/copilot_proxy.bats`
- `tests/fixtures/copilot-shim-hardening.mjs`
- [`copilot-proxy-openai-model-silent-stall`](copilot-proxy-openai-model-silent-stall.md)
