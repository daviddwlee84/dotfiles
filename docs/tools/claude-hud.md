# claude-hud (Claude Code statusline)

[claude-hud](https://github.com/jarrodwatts/claude-hud) renders the multi-line
HUD above the Claude Code prompt: model badge, context bar, cost, cache
countdown, tool activity, git status.

This page is about **reading the numbers correctly**. Several of them mean
something different from what they look like, and two of them legitimately
disagree with each other. Install / upgrade mechanics live in
[upgrades.md](../this_repo/upgrades.md); the `enabledPlugins` decision lives in
[lsp.md](lsp.md) § Via Claude Code plugins.

## Where it is wired

| Thing | Location |
|---|---|
| Config (SSOT) | [`dot_claude/plugins/claude-hud/config.json`](../../dot_claude/plugins/claude-hud/config.json) — a plain managed file; live edits are reverted on `chezmoi apply` |
| `statusLine.command` | the `overlay` heredoc in [`dot_claude/modify_settings.json.tmpl`](../../dot_claude/modify_settings.json.tmpl) |
| Install / refresh | [`claude_hud_sync.py`](../../dot_ansible/roles/coding_agents/files/claude_hud_sync.py), via `just upgrade-plugins` |
| Full flag schema | `src/config.ts` inside the versioned cache dir |

The plugin is deliberately **disabled** in `enabledPlugins`. The HUD still
renders because `statusLine.command` globs the cache path and execs
`dist/index.js` directly, never resolving through the plugin loader. The only
casualty is `/claude-hud:setup` and `/claude-hud:configure` — which you would
not want anyway, since anything they write gets reverted on the next apply.
Edit the config source instead.

## `Tokens` is a running total, not a water level

The single most confusing number. On a 1M-context session you will routinely
see something like `Tokens 22.5M`.

claude-hud sums `message.usage` over **every assistant message in the
transcript** (`sessionTokens.inputTokens += …`), i.e. over every API request in
the session. LLM inference is stateless, so each turn re-sends the whole
conversation — the prefix at turn 100 is counted for the 100th time.

Measured on a real transcript in this repo:

```text
508 API responses, 1 compaction
CUMULATIVE SUM  : 103.88M   <- what the HUD prints
  in=92k  out=831k  cache_create=4.66M  cache_read=98.30M
PEAK SINGLE REQ : 383k      <- the only figure bounded by the context window
ratio           : 271x
```

The ratio is roughly *turns × average context*. Nothing pathological is
happening, and **compaction is not the cause** — one compaction across 508
requests, and compaction *reduces* subsequent context anyway.

If you want the number that the context window actually constrains, read the
`Context` bar (`218k/1.0M`), not `Tokens`.

## `Tokens` counts the main thread only

Subagent and workflow turns are **not** in the transcript Claude Code hands to
the statusline on stdin. They live in a sibling directory:

```text
~/.claude/projects/<project>/<session-id>.jsonl              <- main thread, what the HUD reads
~/.claude/projects/<project>/<session-id>/subagents/agent-*.jsonl   <- never read
```

No `isSidechain` records appear in the main file either. Measured on one real
session here: **1,333,449 main-thread tokens vs 814,250 subagent tokens** — the
HUD under-reported by ~38%. Expect the gap to widen the more you fan out.

## `Cost` does *not* share that blind spot

`Cost` and `Tokens` come from different places, which is why they can look
mutually inconsistent. `src/cost.ts` prefers the native figure and only falls
back to a local estimate:

```js
const nativeCostUsd = getNativeCostUsd(stdin, options);
if (nativeCostUsd !== null) return { totalUsd: nativeCostUsd, source: 'native' };
const estimate = estimateSessionCost(stdin, sessionTokens, options);  // fallback
```

- **native** — Claude Code's own `cost.total_cost_usd` on stdin. This is the
  normal path for a subscription session.
- **estimate** — derived from `sessionTokens`, so it *does* inherit the
  main-thread blind spot above. Only used when stdin carries no cost.

Claude Code's accumulator adds every request unconditionally:

```js
if (e.totalCost += r, e.requestCount++, t.attributionAgent)
    zUo(e.byAgent, t.attributionSkill ?? t.attributionAgent, r)
```

`attributionAgent` only drives a per-agent breakdown; it does not gate the
total. So **`Cost` includes subagents and workflows, `Tokens` does not.** When
the two disagree, `Cost` is the complete one.

## Cache: input-side only, and the countdown is a snapshot

### There is no output cache

Anthropic prompt caching applies to the **input prefix** only. The four usage
fields:

| Field | Meaning | Rough price |
|---|---|---|
| `input_tokens` | fresh input, not served from cache | 1× |
| `cache_creation_input_tokens` | prefix **written** to cache | 1.25× |
| `cache_read_input_tokens` | prefix **read** from cache | **0.1×** |
| `output_tokens` | generated tokens | output rate |

This is why the breakdown above shows `in=92k` against `cache_read=98.30M`:
after the first request almost the entire prefix (system prompt, tool
definitions, history) hits cache, and only the newest delta is fresh.

Output is never cached as output — but this turn's output becomes part of next
turn's input prefix, and *then* becomes cacheable. That is the only route by
which generated text enters the cache.

### The countdown freezes when idle — by design, not a bug

`showPromptCache` renders a plain arithmetic expression, evaluated at render
time (`src/render/lines/prompt-cache.ts`):

```js
const remainingMs = (lastAssistantResponseAt.getTime() + ttlSeconds * 1000) - now;
```

There is no timer inside claude-hud. The value only changes when **Claude Code
re-invokes the statusline command**, which it does on state change (debounced
300 ms), never on a wall clock. So:

- **During an active turn** it tends to sit near `5m 0s`, because
  `lastAssistantResponseAt` advances with every assistant message and an agent
  turn produces one every few seconds. It is genuinely resetting, not stuck.
- **Once the turn ends** nothing triggers a re-render, so the last computed
  string stays frozen on screen.

The countdown is live — invoking the command by hand on a fixed transcript
shows `5m 0s → 4m 56s → 4m 52s` across three calls four seconds apart. The
practical limitation is the inverse of what you want: it cannot show you a
nearly-expired cache while you sit idle, which is precisely when that would be
useful. Treat it as "how fresh was the cache at the last render".

Why it matters in money: letting the TTL lapse means the prefix is re-billed as
`cache_creation` (1.25×) instead of `cache_read` (0.1×) — a 12.5× swing on the
prefix. `promptCacheTtlSeconds` defaults to 300 and should match the TTL your
requests actually use.

## First-line truncation follows a fixed order

Segments render in this native order, and the line is cut at terminal width:

```text
model, project, advisor, sessionName, version, extra, duration, cost, speed, auth
```

`cost` is 8th of 10, so it is among the first things to disappear — you get
`Cost $…` while a random session slug survives. Do not fix this by switching
elements off; reorder instead. `orderFirstLineParts` emits listed segments in
your order and **appends every unlisted key after them**, so a partial list
works and whatever lands last is what truncation eats:

```json
"projectLineOrder": [
  "model", "project", "duration", "cost",
  "extra", "advisor", "speed", "auth",
  "sessionName", "version"
]
```

`modelFormat: "compact"` additionally drops the `(1M context)` suffix, which the
Context line already reports as `218k/1.0M`.

## `sessionName` is a random slug unless you name the session

`magical-noodling-horizon` and friends are a fallback, not an identifier:

```js
result.sessionName = customTitle ?? latestSlug;
```

`customTitle` comes from `claude -n <name>` / `--name <name>`, described by the
CLI as *"Set a display name for this session (shown in the prompt box, /resume
picker, and terminal title)"*. Without it you get an auto-generated slug.

It is **unrelated to the session UUID** that `--resume` keys on. It is purely a
human-readable label for the `/resume` picker and the terminal title — useless
noise until you start launching named sessions, at which point it becomes the
fastest way to find a session again.

## Related

- [upgrades.md](../this_repo/upgrades.md) — version drift, the install-only
  trap, and the full list of opt-in elements added after `0.0.11`
- [lsp.md](lsp.md) — the `enabledPlugins` map
- [`pitfalls/claude-hud-shows-raw-model-id.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/claude-hud-shows-raw-model-id.md)
  — raw `claude-opus-5[1m]` in the badge means Claude Code is too old to send
  `display_name`
- [`pitfalls/claude-hud-usage-statusline-stale.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/claude-hud-usage-statusline-stale.md)
