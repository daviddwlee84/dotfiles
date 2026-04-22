# OpenCode

Notes for the local OpenCode setup on this machine — covers the chezmoi-managed overlay, the upstream `title` agent regression, and the GitHub Copilot Claude Opus stream-stall workaround.

## How the global config is managed

The `~/.config/opencode/opencode.json` global config is **partially** managed via a chezmoi `modify_` overlay (jq deep-merge). See [agent-overlays.md → OpenCode](agent-overlays.md#opencode--agentsopencodeoverlayjson) for the canonical overlay contents and per-key rationale.

The legacy `~/.config/opencode/config.json` filename is migrated to the modern `opencode.json` once per machine by [`run_once_before_50_opencode_migrate.sh.tmpl`](../../run_once_before_50_opencode_migrate.sh.tmpl); see [agent-overlays.md → OpenCode legacy migration](agent-overlays.md#opencode-legacy-configjson-migration).

What's intentionally **not** in the overlay (i.e. left as machine-local state):

- `plugin` paths — the local config carries an absolute path under `~/.config/opencode/plugins/`; an overlay would clobber per-machine paths.
- Auth tokens, telemetry IDs, last-used provider hints — written by the CLI at runtime; overlay would either erase them or fight the CLI on every apply.

If you ever need to share a plugin across machines, package it as an npm module and add it to the overlay's `plugin` array as a package name (not a `file://` path).

## Known issue: session title stuck as `New session - ...`

Observed on this machine starting with OpenCode `1.4.6`; still applies on `1.14.x`.

Symptom:

- new sessions stay at the fallback title `New session - <timestamp>`
- title generation does not complete automatically

Root cause:

- the hidden `title` agent uses `github-copilot/gpt-5-mini` for a lightweight title request
- OpenCode sends `reasoning_effort = "minimal"`
- `gpt-5-mini` rejects that value because it only accepts `low`, `medium`, or `high`

Upstream tracking:

- [anomalyco/opencode#22796](https://github.com/anomalyco/opencode/issues/22796) — title agent uses unsupported `reasoning_effort: minimal`

### Workaround (managed)

The overlay enforces:

```json
{
  "agent": { "title": { "reasoningEffort": "low" } },
  "small_model": "github-copilot/gpt-5-mini"
}
```

`reasoningEffort: "low"` sidesteps the `minimal` rejection. `small_model` is pinned explicitly so the title-agent + summarisation pipeline always uses the cheap model regardless of which provider the main session uses.

### When to remove the workaround

Drop the `agent.title.reasoningEffort` override from the overlay after verifying all of the following:

- the upstream regression is fixed
- a new OpenCode version is installed locally
- a fresh session auto-generates a non-fallback title
- the OpenCode log no longer shows `reasoning_effort: "minimal"` for the title request

## Claude Opus stream stall on GitHub Copilot

When using the `github-copilot/claude-opus-4.x` channel for long-running tool calls — typically a single large `write` against a multi-thousand-line file — the TUI shows a repeating `~ Preparing write...` followed by `Tool execution aborted`, sometimes for many minutes, until the user hits ESC.

### Diagnosis from log

`~/.local/share/opencode/log/<timestamp>.log` shows:

- the same `messageID` re-streaming over and over with the SDK retry-backoff sequence: `+2009ms → +4013ms → +8045ms → +16011ms → +30023ms → +30015ms ...` (the `30000ms` cap is the SDK's max backoff)
- between each retry, a `+60000ms` gap with no `message.part.delta` events — the SSE stream went idle and the GitHub Copilot proxy server-side closed it
- the model had already emitted `tool_use` for `write` but the JSON `input` field is still streaming when the SSE dies — that's exactly what produces the "Preparing write..." → "aborted" UX, because the tool call is structurally incomplete

### Root cause

GitHub Copilot's proxy in front of the Anthropic upstream enforces an idle timeout (community-observed at ~60 s) on streaming responses. Claude Opus generating a very large single tool-call payload can stay below the chunk emission threshold long enough to trip this, after which the connection silently dies. Direct Anthropic API does not have this behaviour. Sonnet trips it less often than Opus because it generates faster.

There is **no client-side flag to disable the proxy's idle timeout** — it's enforced server-side. The two viable mitigations are: (1) cancel-and-retry early so the SDK isn't blocked the full request timeout waiting for chunks that will never arrive, and (2) avoid emitting one giant tool call in the first place.

### Mitigation (managed)

The overlay sets:

```json
{
  "provider": {
    "github-copilot": {
      "options": { "timeout": 600000, "chunkTimeout": 20000 }
    }
  }
}
```

- `chunkTimeout: 20000` cancels a stalled stream after 20 s of silence and lets the SDK reconnect, instead of waiting the full request `timeout`.
- `timeout: 600000` (10 min) extends the request-level cap so legitimately long generations aren't aborted prematurely after the first reconnect succeeds.

This shrinks the visible "stuck" window from ~minutes to ~tens of seconds and lets retries actually make progress instead of hitting the same dead connection.

### Behavioural mitigation (not managed)

If a generation is still failing repeatedly, prompt the agent to:

1. write a minimal skeleton first via a small `write`,
2. fill each section incrementally via multiple `edit` calls.

This avoids the giant single-tool-call payload that triggers the stall in the first place. Not enforced via global `instructions` because that bloats every session's system prompt; better to add it as a per-project `AGENTS.md` rule when the repo is known to produce large generated files.

### When to remove the mitigation

The `chunkTimeout` override can stay indefinitely — it's a defensive setting that doesn't hurt. Reconsider when:

- GitHub Copilot publishes that the proxy idle timeout has been raised or removed for the Anthropic channel, or
- you switch to direct Anthropic API (`provider.anthropic.options.apiKey`) and stop using the Copilot channel for Claude entirely.
