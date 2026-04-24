# Backlog Research

Long-form research, design notes, and paused troubleshooting for items listed in
[`../TODO.md`](../TODO.md). One file per topic, named with a slug that matches
the TODO entry.

## Why this exists

`TODO.md` is the **index** — short titles with priority/effort tags. This folder
is the **knowledge base** — the actual investigation, options considered,
benchmarks, error messages, and decisions that informed the TODO entry. The goal
is **resume-friendliness**: when you (or an agent) come back to an item three
months later, the doc here lets you pick up in 5 minutes instead of re-running
30 minutes of investigation.

This folder is `chezmoi`-ignored (see `.chezmoiignore.tmpl` → `backlog/**`) — it
is repo metadata for maintainers, not user-facing config to deploy.

## When to add a doc here

Add a `backlog/<slug>.md` file when **any** of these apply:

- The TODO item carries a `P?` tag (it requires evaluation; record what was tried)
- You did meaningful troubleshooting but didn't ship a fix (capture the trace
  before it evaporates)
- Multiple options were considered (record the trade-offs, not just the winner)
- An external blocker exists (waiting on upstream release, host availability)
- The implementation is `[L]` or `[XL]` (architectural; needs design before code)

`[S]` items rarely need a doc unless there's surprising context.

## When NOT to add a doc here

- Item is `[S]` and obvious (e.g., "change a TOML key") — just put the file path
  in the TODO entry
- Already covered by a `docs/this_repo/*.md` or `docs/tools/*.md` page
  (cross-link instead, that's user-facing reference)
- Speculation only ("would be cool to...") with no investigation — keep it as a
  one-liner in `TODO.md` first; promote to a doc when you actually look into it

## File template

```markdown
# <Topic title>

**Status**: P? / P1 / P2 / P3 / blocked / deferred / superseded
**Effort**: S / M / L / XL
**Related**: `TODO.md` · code paths · related docs

## Context

Why this surfaced. Trigger (conversation, bug, new tool, recurring annoyance).
Date helps — "2026-04, came up while reviewing starship prompt".

## Investigation

What's already been tried / read / measured. **This is the section that saves
future-you time.** Be specific:

- Commands run + relevant output
- Docs/issue/SO links read
- Benchmark numbers
- Error messages copy-pasted in full (not paraphrased)

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. … | … | … |
| B. … | … | … |

## Current blocker / open questions

Why this is still on the backlog. One of:

- Waiting on upstream X (link)
- Need host/data Y to verify
- Trade-offs unclear, need user preference
- Effort estimate exceeds current budget

## Decision (if any)

`2026-04 deferred — waiting for X release` or
`2026-04 chose option B because …`

Dates matter. A 6-month-old "decided to use mise" needs re-validation.

## References

Issues, PRs, SO links, related discussions.
```

## Index

Add new entries here as you create them. Keep alphabetical.

| Slug | Status | TODO entry |
|---|---|---|
| [`ai-capture-non-tmux-output`](ai-capture-non-tmux-output.md) | P2 deferred / P3 rejected | "aicapture: non-tmux output capture (Tier 2 tee / Tier 3 script/PTY)" |
| [`chezmoiscripts-namespace-refactor`](chezmoiscripts-namespace-refactor.md) | P2 ready | "Migrate run_onchange scripts into .chezmoiscripts/{global,repo}/" |
| [`specstory-opencode-support`](specstory-opencode-support.md) | P? deferred | "specstory: enable opencode auto-wrap when upstream lands" |
| [`starship-context-modules`](starship-context-modules.md) | P1 ready | "Starship status-aware modules" |
| [`tmux2k-tuning`](tmux2k-tuning.md) | P1 ready | "tmux2k bandwidth bug" + "tmux2k theme alignment" |
| [`tmux-window-status-indicators`](tmux-window-status-indicators.md) | P? deferred | "tmux window status indicators (running / idle / error)" |
