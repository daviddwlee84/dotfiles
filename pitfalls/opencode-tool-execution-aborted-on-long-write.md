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

- Happens consistently when the agent tries to write a single file ≥ ~800–1000 lines via the `write` tool, but **smaller files also reproduce** in projects with slow LSP / aggressive formatters (see [Defect A root cause](#defect-a--write-tools-post-write-side-effects-use-effectordie-the-main-bug)).
- Retrying the same `write` tool call produces the same abort. **Counter-intuitive: the file may actually be on disk despite the abort message — always [verify](#verification-before-re-writing) before retrying.**
- Most reliably triggered with `claude-opus-4.x` / `claude-sonnet-4.x` over the `github-copilot` provider.
- Claude Code (direct Anthropic API) does **not** exhibit this on the same prompt — the failure is OpenCode-side.

**First seen**: 2026-05 (this repo, on `github-copilot/claude-opus-4.7`)
**Affects**: OpenCode 1.14.x (confirmed 1.14.29 and 1.14.48) on darwin and linux; `provider: github-copilot` running Claude models. Likely affects other relay providers as well.
**Status**: **upstream root cause identified 2026-05; partial fix shipped in v1.15.11 (#26177), main fix has PR ready for review (#26347 closes #19604, #11112, #11630, #16816)**. See [Status by issue](#status-by-issue) below. **#26177's PR has shipped**, so the `prefill 400` follow-on after the abort is no longer expected on 1.15.11+. The silent abort itself (#19604) still reproduces. Workaround (skeleton-then-edit) still applies until #26347 merges, **but see the new [Verification before re-writing](#verification-before-re-writing) step** — the file may already be on disk despite the abort message.

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

**Upstream OpenCode bug.** Two independent defects converge on the same observable symptom; one is fixed in v1.15.11, the other has a PR ready.

### Defect A — Write tool's post-write side-effects use `Effect.orDie` (the main bug)

Root cause located by [PR #26347](https://github.com/anomalyco/opencode/pull/26347) (open, ready for review 2026-05-09, external contributor):

> The `Write` tool runs format / BOM-sync / bus events / LSP touch / LSP diagnostics inline with the actual disk write, then pipes the whole `Effect` through `Effect.orDie`. Any throw from a post-write step becomes an unhandled defect and surfaces to the user as a silent abort with no error message — **even though the bytes have already been written to disk successfully**.

**Implications that change how you respond to the symptom**:

- The file size threshold ("≥ ~800–1000 lines") is misleading. Size only correlates because **larger files make the LSP / formatter / BOM-sync more likely to throw** (LSP server stalling on a long file, formatter OOM, BOM re-read race, bus publish failure). A 574-line file in the right project also reproduces.
- **The bytes are on disk.** The agent (and you, watching the TUI) think the write failed. Often it didn't — only the post-write hooks did. **Always [verify](#verification-before-re-writing) before re-trying.**
- The known skeleton-then-edit workaround "works" not because `edit` uses a different code path (it goes through similar side-effects), but because **smaller writes give the post-write hooks less to choke on**.

PR #26347's fix wraps each post-write side-effect in `Effect.catchCause` and logs a warning instead of dying. The actual `fs.writeWithDirs` still propagates its own errors, so OS-level failures (EACCES, ENOSPC, EISDIR) continue to fail the tool as before.

### Defect B — Run loop continues on orphaned interrupted tools (fixed in v1.15.11)

[#26177](https://github.com/anomalyco/opencode/issues/26177) + [PR #26178](https://github.com/anomalyco/opencode/pull/26178) → **shipped in v1.15.11** release notes ("Resumed sessions no longer continue orphaned interrupted tools.").

When a tool aborts mid-stream, `processor.cleanup()` marks it `{ state.status: "error", metadata: { interrupted: true } }`. Pre-fix, the run loop's `hasToolCalls` check counted that orphan as open work and fired another LLM request. `convertToModelMessages` split the assistant message around the orphan, so the resulting history ended with an assistant turn — which Anthropic rejected with HTTP 400:

```
This model does not support assistant message prefill.
The conversation must end with a user message.
```

Post-fix, orphaned-interrupted tool parts are excluded from the run-loop continuation, so the `prefill 400` follow-on no longer occurs after an aborted write. The **initial** `~ Preparing write... Tool execution aborted` symptom is still the responsibility of Defect A.

### Local evidence (`opencode.db`, this machine, 2026-05-28)

```sql
SELECT COUNT(*) FROM part WHERE data LIKE '%Tool execution aborted%';
-- 74
SELECT COUNT(*) FROM part WHERE data LIKE '%"interrupted":true%';
-- 56  (Defect B pattern)
SELECT COUNT(*) FROM part WHERE data LIKE '%does not support assistant message prefill%';
-- 3   (Defect B's downstream consequence)
SELECT json_extract(data,'$.state.status'), COUNT(*) FROM part
  WHERE json_extract(data,'$.tool') = 'write' GROUP BY 1;
-- completed | 117
-- error     |  50    (30% error rate on `write`)
```

All 50 errored `write` parts have `state.input` reduced to `{}` — input arguments were force-cleared at cleanup, so we cannot retroactively recover the target filepaths from the DB to verify "the file was on disk" against the user's actual repos. Going forward, **verify at the time the abort happens** (see next section).

### Architecturally, why Claude Code doesn't reproduce

OpenCode interposes its own server between the TUI and the upstream provider, with an SSE relay that re-parses streamed `tool_use` JSON and a richer set of post-write side-effects (LSP / format / BOM-sync). Claude Code talks to Anthropic directly with a thinner write path. The Effect-orDie defect in OpenCode's write tool has no analog there.

### What is **not** the cause

- **`provider.*.options.timeout`** — controls the request-level timeout (time to first byte / total request budget). `~ Preparing write...` aborts well within this window; bumping `timeout` does nothing.
- **`provider.*.options.chunkTimeout`** — controls "max gap between streamed chunks before abort". Setting this *low* will make the symptom **worse** (more aggressive aborts). Leaving it unset (default) is correct.
- **Local network / VPN** — Claude Code over the same network does not reproduce.
- **Chezmoi `modify_opencode.json.tmpl` overlay merge** — the live config (`opencode debug config`) shows the merged values are correct.

## Status by issue

| Upstream ref | What it covers | Status (as of 2026-05-28) |
|---|---|---|
| [#19604](https://github.com/anomalyco/opencode/issues/19604) — Write tool fails silently on large files | The main Defect A bug | **Root cause identified.** PR [#26347](https://github.com/anomalyco/opencode/pull/26347) ready for review (2026-05-09). Issue assigned to `kitlangton` (core). Same PR also closes #11112, #11630, #16816. Not merged yet. |
| [#26177](https://github.com/anomalyco/opencode/issues/26177) — Run loop continues on orphaned interrupted tools | Defect B (prefill 400 cascade) | ✅ **Closed**. PR [#26178](https://github.com/anomalyco/opencode/pull/26178) merged → **shipped in v1.15.11**. |
| [#25577](https://github.com/anomalyco/opencode/issues/25577) — Tool execution aborted (general) | Feature request for auto-restart after abort | Open, no PR. Assigned to `nexxeln`. Description is more "auto-restart UX" than root-cause analysis. |
| [#24927](https://github.com/anomalyco/opencode/issues/24927) — `JSON error injected into SSE stream` | Tail symptom of the abort cascade | Open, no PR. Assigned to `jlongster`. Reported on v1.14.29, no further activity. |

## Verification before re-writing

**New first response when you see `~ Preparing write... Tool execution aborted` in the TUI** (per PR #26347's hypothesis that the bytes were already written before the post-write hook threw):

1. Pause — do **not** let the agent retry the same `write` immediately.
2. Open another terminal and check the target file path:

   ```sh
   ls -la <expected/path/to/file>
   # OR if you know the project but not the exact filename:
   git -C <project-dir> status --short | grep '^??'  # new untracked files
   ```

3. If the file exists **and the content looks complete** (line count matches what the agent was trying to write; last paragraph is closed; etc.), the write actually succeeded. Tell the agent:

   > "The file is on disk at `<path>` despite the abort message — please continue from there."

   You can then proceed without skeleton-then-edit.

4. If the file is missing or visibly truncated, fall through to the [Workaround](#workaround) below (skeleton-then-edit).

**Why this matters**: in pre-fix code, the agent's narration ("the write failed, let me try again") is wrong about half the time. Acting on the wrong assumption wastes a 3-5 retry cycle and ends up writing the same content twice.

This step becomes unnecessary once PR #26347 merges and ships.

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
- [`pitfalls/opencode-docker-opentui-glibc-loader-missing.md`](opencode-docker-opentui-glibc-loader-missing.md) — different bug, but similar pattern of "OpenCode-internal layer fails in a way that produces a misleading error message". Listed for grep convenience.
- `docs/tools/agent-overlays.md` — describes how `dot_config/opencode/modify_opencode.json.tmpl` works and what we deliberately don't manage. Cross-references this pitfall from the OpenCode section.
- **Real-world test of the pitfall** (meta): the 2026-05-28 edit session that landed this revision hit the same `Tool execution aborted` symptom on its **own pitfall doc** during a section-reorder edit. Per the verification step, the doc was already in the correct state on disk — the edit was unnecessary, and the agent's narration ("the edit failed, let me retry") would have been wrong. Section order was confirmed via `grep "^## " <file>` instead of re-editing.
- Upstream issues to watch (close them in your watchlist when this pitfall's status moves to "fixed"):
  - <https://github.com/anomalyco/opencode/issues/19604> — main issue (Defect A); has PR
  - <https://github.com/anomalyco/opencode/pull/26347> — main PR (Defect A fix); ready for review 2026-05-09, not yet merged
  - <https://github.com/anomalyco/opencode/issues/11112>, <https://github.com/anomalyco/opencode/issues/11630>, <https://github.com/anomalyco/opencode/issues/16816> — duplicates that PR #26347 also closes
  - <https://github.com/anomalyco/opencode/issues/25577> — generic "Tool execution aborted" feature request (auto-restart)
  - <https://github.com/anomalyco/opencode/issues/24927> — `JSON error injected into SSE stream` tail symptom
  - ~~<https://github.com/anomalyco/opencode/issues/26177>~~ + ~~<https://github.com/anomalyco/opencode/pull/26178>~~ — Defect B, ✅ shipped in v1.15.11
- Upgrade path when fixed: with `autoupdate: true` already in the overlay, the next `opencode` launch after upstream releases the fix picks it up automatically. After a few weeks of clean runs on a post-PR-#26347 version, update this pitfall's `Status:` line to `fixed upstream in vX.Y.Z` and leave the file as historical record.
