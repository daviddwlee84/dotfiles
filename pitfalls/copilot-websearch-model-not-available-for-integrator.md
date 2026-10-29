# Copilot WebSearch returns model_not_available_for_integrator for vscode-chat

**Symptoms** (grep this section): `Web Search`, HTTP 400,
`model_not_available_for_integrator`, `The requested model is not available for integrator "vscode-chat". Verify the correct Copilot-Integration-Id header is being sent.`
**First seen**: 2026-10
**Affects**: `@jeffreycao/copilot-api@2.5.2` with a retired search model
**Status**: fixed locally; upstream startup migration added in 2.7.36

## Symptom

Claude Code's ordinary model selection can be valid while WebSearch fails:

```text
API Error: 400 {"error":{"message":"The requested model is not available for integrator \"vscode-chat\". Verify the correct Copilot-Integration-Id header is being sent.","code":"model_not_available_for_integrator","param":"model","type":"invalid_request_error"}}
```

## Root cause

The maintained fork already supports pure Anthropic server-side `web_search`
requests in 2.5.2. It switches those requests to its own
`messageApiWebSearchModel`, runs Copilot Responses search, then reconstructs
Anthropic search-result blocks. This setting is independent of `copilot-model`
and the Claude Code main/role aliases.

The stored search model was `gpt-5-mini`, absent from the running account's
`/v1/models` catalog. `gpt-6-luna` was listed with Responses support. The backend
correctly sent `copilot-integration-id: vscode-chat`; the error's header advice
did not identify the actual stale model setting in this case.

## Workaround

1. Run `copilot-proxy doctor`; inspect its **WebSearch** section.
2. Privately back up `${COPILOT_API_HOME:-$HOME/.local/share/copilot-api}/config.json`.
3. Change only `messageApiWebSearchModel` to a served Responses model. The
   verified repair on this account was `"messageApiWebSearchModel": "gpt-6-luna"`.
4. Wait for active and queued work to finish, run `copilot-proxy restart`, and
   retry the search. A catalog match alone is not a successful inference test.

Controlled reproduction on the same 2.5.2 package:

| Config / query | Observed result |
|---|---|
| Stored `gpt-5-mini`, pure WebSearch | HTTP 400 with the exact integrator error |
| Isolated `gpt-6-luna`, OpenAI Apps SDK query | HTTP 200, source URL and Anthropic search-result blocks |
| Isolated `gpt-6-luna`, Anthropic apps/MCP query, streaming | source URL, no error events, final `message_stop` |

An initial non-streaming Anthropic query returned zero sources despite HTTP
200; the streaming retry returned a source. Check content and terminal events,
not just HTTP status. Temporary backends used separate config and SQLite files;
their processes and credential copies were removed after testing.

## Prevention

`doctor` validates the independent search model without writing config or sending
inference. Missing settings, incomplete metadata and provider aliases remain
unverified; disabled search is not a failure.

Upstream 2.6.7 changed the default to `gpt-6-luna`. Version 2.7.36 additionally
migrates exact `gpt-5-mini` values in `alphaSearchModel`,
`messageApiWebSearchModel` and `claudeAutoModel` at startup, preserving custom
models and empty strings. The initial local repair retained 2.5.2; after the
separate compatibility trial, the Mac and built-in pin were explicitly upgraded
to 2.8.2 with the old generation retained for rollback.

## Related

- [Copilot proxy guide](../docs/tools/copilot-claude-proxy.md)
- [Upstream default change](https://github.com/caozhiyuan/copilot-api/releases/tag/v2.6.7)
- [Upstream migration](https://github.com/caozhiyuan/copilot-api/commit/269421ca75c8fa127ed84c2de337e256d755bd3f)
