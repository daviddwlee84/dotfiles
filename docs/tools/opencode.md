# OpenCode

Notes for the local OpenCode setup on this machine — covers the chezmoi-managed overlay, the upstream `title` agent regression, and the GitHub Copilot Claude Opus stream-stall workaround.

## How the global config is managed

The `~/.config/opencode/opencode.json` global config is **partially** managed via a chezmoi `modify_` overlay (jq deep-merge). See [agent-overlays.md → OpenCode](agent-overlays.md#opencode-agentsopencodeoverlayjson) for the canonical overlay contents and per-key rationale.

The TUI-specific config `~/.config/opencode/tui.json` (separate file, separate schema — see upstream [Config → TUI](https://opencode.ai/docs/config/#tui)) is also managed via a `modify_` overlay; see [agent-overlays.md → OpenCode TUI](agent-overlays.md#opencode-tui-agentsopencodetuioverlayjson) for what's pinned (currently `keybinds.leader`, `mouse`, `diff_style`, `scroll_acceleration.enabled`) and what's intentionally left to the TUI's runtime customisation panel (`theme`, `username_toggle`, etc.).

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

There is **no client-side flag to disable the proxy's idle timeout** — it's enforced server-side.

### Upstream tracking

- [anomalyco/opencode#17578](https://github.com/anomalyco/opencode/issues/17578) — exact symptom match: `Write tool SSE timeout with claude-opus-4.x via GitHub Copilot when generating long markdown files`. Reporter found that **Pyright LSP diagnostics get appended to tool responses** and inflate the SSE payload, making the stall more likely. Even writing a `.md` file can trigger a full project re-scan in repos containing Python sources without a configured venv. Fix in PR `#18894` (not merged at time of writing).
- [anomalyco/opencode#17574](https://github.com/anomalyco/opencode/issues/17574), [#17307](https://github.com/anomalyco/opencode/issues/17307), [#17318](https://github.com/anomalyco/opencode/issues/17318), [#17336](https://github.com/anomalyco/opencode/issues/17336) — additional reports of the same SSE-stall pattern; `#17307` is the original issue under which `chunkTimeout` was added as a stop-gap.
- [anomalyco/opencode#20466](https://github.com/anomalyco/opencode/issues/20466) — **`chunkTimeout` does not actually retry**: when the chunk-timeout fires, the resulting `SSE read timed out` error is wrapped as `NamedError.Unknown` and the `retryable()` predicate in `retry.ts` rejects it (fails the `JSON.parse()` branch). Net effect: setting `chunkTimeout` converts a silent multi-minute hang into a hard failure with **no automatic retry**, which is often worse UX than leaving it unset and relying on the SDK's request-level retry. Fix in PRs `#21727` and `#23501` (neither merged).
- [anomalyco/opencode#21173](https://github.com/anomalyco/opencode/issues/21173) — analogous problem on the OpenAI Responses provider (different transport, same shape).

### Mitigation (managed)

The overlay sets:

```json
{
  "provider": {
    "github-copilot": {
      "options": { "timeout": 600000 }
    }
  }
}
```

- `timeout: 600000` (10 min) extends the request-level cap so legitimately long generations aren't aborted prematurely.
- **`chunkTimeout` is intentionally NOT set.** A previous version of this overlay set `chunkTimeout: 20000` on the assumption that early cancel-and-retry would unstick the stream faster than waiting the full request timeout. Live testing on this machine showed the setting fires correctly (`SSE read timed out` at ~20 s, visible in `~/.local/share/opencode/log/2026-04-22T105313.log` lines 183, 257) but the error is **not retried** because of upstream bug `#20466` — `retryable()` in `retry.ts` rejects the error class. Net result was "20 s hang then hard fail with no recovery", which is worse than "silent hang then SDK request-level retry". Removed pending one of the linked PRs landing.

### LSP-payload aggravator (Action 3 — managed at repo root)

Per `#17578` the SSE payload includes diagnostics from any LSP server OpenCode auto-spawns for files in the working tree. In a chezmoi-managed dotfiles repo with stray Python scripts using PEP 723 inline-script-deps (`#!/usr/bin/env -S uv run --script`), Pyright cannot resolve the inline-declared dependencies and emits dozens of `reportMissingImports` diagnostics per file, which then ride along on every tool response. To suppress this noise the chezmoi repo root carries a [`pyrightconfig.json`](../../pyrightconfig.json) that:

- excludes ansible role trees, chezmoi source dirs (`dot_*/`), agent transcript dirs (`.specstory/`, `.claude/`, `.cursor/`, `.opencode/`), and `backups/`,
- sets `reportMissingImports = "none"` so PEP 723 scripts stop polluting the diagnostics channel.

This file lives at the repo root (not under any `dot_*/` source path) so it is part of the chezmoi git repo but never deployed to `$HOME`.

### Behavioural mitigation (not managed)

If a generation is still failing repeatedly, prompt the agent to:

1. write a minimal skeleton first via a small `write`,
2. fill each section incrementally via multiple `edit` calls (~50–80 lines each, one logical block per call).

This avoids the giant single-tool-call payload that triggers the stall in the first place. Empirically the most reliable fix in this session — far more effective than any client-side timeout tuning. Not enforced via global `instructions` because that bloats every session's system prompt; better to add it as a per-project `AGENTS.md` rule when the repo is known to produce large generated files.

### When to revisit

- If `#20466` lands (one of PRs `#21727` / `#23501`), re-add `chunkTimeout` to the overlay — it will then actually retry instead of hard-failing.
- If `#17578` / PR `#18894` lands, the LSP-payload aggravator goes away upstream and the root `pyrightconfig.json` becomes a belt-and-suspenders defence rather than a load-bearing fix.
- If GitHub Copilot raises the proxy idle timeout, the entire section can be deleted and the overlay's `timeout` reverted to the upstream default.
- If you switch to direct Anthropic API (`provider.anthropic.options.apiKey`) and stop using the Copilot channel for Claude entirely, the overlay's `provider.github-copilot` block can be dropped.
