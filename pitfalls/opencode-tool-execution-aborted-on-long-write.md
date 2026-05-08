# OpenCode `~ Preparing write... Tool execution aborted` repeats on long file writes

**Symptoms** (grep this section):

```
~ Preparing write...
Tool execution aborted

~ Preparing write...
Tool execution aborted

~ Preparing write...
Tool execution aborted
```

Sometimes terminated by:

```
{"type":"api_error","message":"JSON error injected into SSE stream"}
```

And/or the session footer shows:

```
Build · Claude Opus 4.7 · interrupted
```

- Happens consistently when the agent tries to write a single file ≥ ~800–1000 lines via the `write` tool.
- Retrying the same `write` tool call produces the same abort. No partial content lands on disk.
- Most reliably triggered with `claude-opus-4.x` / `claude-sonnet-4.x` over the `github-copilot` provider.
- Claude Code (direct Anthropic API) does **not** exhibit this on the same prompt — the failure is OpenCode-side.

**First seen**: 2026-05 (this repo, on `github-copilot/claude-opus-4.7`)
**Affects**: OpenCode 1.14.x (confirmed 1.14.29) on darwin and linux; `provider: github-copilot` running Claude models. Likely affects other relay providers as well.
**Status**: **upstream bug, not yet fixed**. Tracked across three open issues + one in-flight PR (see [Related](#related)). Workaround documented (skeleton-then-edit). No repo-side config fix exists — `provider.*.options.timeout` and `chunkTimeout` do not address the root cause.

## Symptom

Inside the OpenCode TUI, the agent announces it is about to call the `write` tool with a long body (typical case: generating a 1000+ line markdown doc in one shot). The status line cycles:

1. `~ Preparing write...`
2. `Tool execution aborted` (no error detail, no partial file)
3. The agent narrates a recovery message and tries again
4. Repeat 3–5× until the agent gives up or the session shows `interrupted`

In some sessions a final SSE payload leaks into the visible output:

```
{"type":"api_error","message":"JSON error injected into SSE stream"}
```

This is the SSE relay's own error channel surfacing into the chat transcript — the request to the model technically completed, but the streamed tool-call JSON was rejected mid-parse.

The user's screenshot confirming this on `github-copilot/claude-opus-4.7` writing long docs is in the chat history that produced this pitfall (2026-05-08).

## Root cause

**Upstream OpenCode bug, multiple overlapping defects on the `write` / SSE / interrupted-tool path.** Not a local config issue, not a network timeout.

Three separate issues converge on the same observable symptom:

| Upstream issue | What it covers | Assignee | State |
|---|---|---|---|
| [#19604 — Write tool fails silently on large files (~1000+ lines)](https://github.com/anomalyco/opencode/issues/19604) | The `write` tool itself silently aborts when content crosses a size threshold; retries produce the same failure; no error returned to the agent | `kitlangton` | open |
| [#25577 — Tool execution aborted](https://github.com/anomalyco/opencode/issues/25577) | Long-running Opus/Sonnet sessions hit `Tool execution aborted` and require a manual `continue` to resume | `nexxeln` | open |
| [#24927 — JSON error injected into SSE stream](https://github.com/anomalyco/opencode/issues/24927) | Tail symptom — the literal `{"type":"api_error","message":"JSON error injected into SSE stream"}` payload that sometimes terminates the abort cascade | `jlongster` | open |
| [#26177 — Run loop continues on orphaned interrupted tools](https://github.com/anomalyco/opencode/issues/26177) + [PR #26178](https://github.com/anomalyco/opencode/pull/26178) | After an aborted tool, the run loop keeps continuing with an orphaned `tool_use` block, which trips a `model does not support assistant message prefill` 400 from Anthropic | `edevil` (PR open) | PR in review |

Architectural reason this never reproduces in Claude Code: OpenCode interposes its own server between the TUI and the upstream provider, with an SSE relay that re-parses streamed `tool_use` JSON. When the model emits a large tool-call payload (e.g. `write` with `content` ~1000+ lines), the SSE re-assembly stage hits an edge case at chunk boundaries, the `write` tool sees a partial / malformed payload, and aborts. Claude Code talks to Anthropic directly, no relay layer, so the fault path doesn't exist.

### What is **not** the cause

- **`provider.*.options.timeout`** — controls the request-level timeout (time to first byte / total request budget). `~ Preparing write...` aborts well within this window; bumping `timeout` does nothing.
- **`provider.*.options.chunkTimeout`** — controls "max gap between streamed chunks before abort". Setting this *low* will make the symptom **worse** (more aggressive aborts). Leaving it unset (default) is correct.
- **Local network / VPN** — Claude Code over the same network does not reproduce.
- **Chezmoi `modify_opencode.json.tmpl` overlay merge** — the live config (`opencode debug config`) shows the merged values are correct.

## Workaround

**Use the `write` tool only for a short skeleton, then build up content with `edit` calls.** This is the same workaround called out in upstream issue #19604 and was independently confirmed by the user during the session that produced this pitfall ("如果太長寫入失敗 那就先建立 template 然後一段段寫入").

Concrete pattern when the agent needs to produce a long file:

1. `write` a skeleton ≤ ~200–300 lines containing only headings + section anchors + brief placeholder text.
2. For each section, `edit` the placeholder into the real content. Each `edit` body stays well below the size threshold.
3. If a single section is itself > ~300 lines, split it into multiple `edit` calls appending to a sentinel comment.

The `edit` tool path uses a different code path that is not affected by the bug.

There is **no config-file workaround**. OpenCode does not expose:

- a `tools.write.maxLines` / `tools.write.chunkSize` knob
- an `auto-retry on tool abort` setting (#25577 is a feature request, not yet implemented)
- a way to disable the SSE re-parse layer for one provider

## Prevention

- **Do not** add `chunkTimeout` to `.chezmoitemplates/agents/opencode.overlay.json` thinking it will help. It will make this worse and degrade other long-running tools (bash, large reads). The existing `provider.github-copilot.options.timeout: 600000` is correct and stays.
- **Do not** switch `autoupdate: true` → manually pinning an old version; the bug is in 1.14.x and the fix will land in a future release. Tracking upstream is correct.
- **Do not** open a duplicate issue. Three are already filed and assigned.
- **When the agent reports repeated `Tool execution aborted` on a `write` call**, immediately tell it (or recognise yourself) to switch to skeleton-then-edit. Do not waste cycles letting it retry.

## Related

- Sibling pitfalls (none yet — this is the first OpenCode-specific entry).
- `docs/tools/agent-overlays.md` — describes how `dot_config/opencode/modify_opencode.json.tmpl` works and what we deliberately don't manage. Cross-references this pitfall from the OpenCode section.
- Upstream issues to watch (close them in your watchlist when this pitfall's status moves to "fixed"):
  - <https://github.com/anomalyco/opencode/issues/19604>
  - <https://github.com/anomalyco/opencode/issues/25577>
  - <https://github.com/anomalyco/opencode/issues/24927>
  - <https://github.com/anomalyco/opencode/issues/26177>
  - <https://github.com/anomalyco/opencode/pull/26178>
- Upgrade path when fixed: with `autoupdate: true` already in the overlay, the next `opencode` launch after upstream releases the fix picks it up automatically. After a few weeks of clean runs, update this pitfall's `Status:` line to `fixed upstream in vX.Y.Z` and leave the file as historical record.
