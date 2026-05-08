# rtk-ai/rtk — adopt as fleet-wide LLM token compressor?

**Status**: P? declined 2026-05 — re-evaluate when v1.0 ships or token-cost becomes the dominant pain
**Effort**: M (brew install + ansible role + per-agent `rtk init` + jq merger for `~/.claude/settings.json` hook block + telemetry-disable env in shared shell tier)
**Related**: [`TODO.md`](../TODO.md) → `[P?/M] rtk-ai/rtk evaluation` · sibling decision [`chezmoi-diff-pager-agent.md`](chezmoi-diff-pager-agent.md) · upstream <https://github.com/rtk-ai/rtk>

## Context

2026-05, conversation prompt: *"另外也看看那個 RTK 是否值得裝 還是說會容易有兼容問題？或是僅適用部分 coding agent？ 總之全面評估一下"*

The question came up alongside the chezmoi diff pager investigation ([`chezmoi-diff-pager-agent.md`](chezmoi-diff-pager-agent.md)) — RTK was floated as a possible solution to "agent gets less-readable output from CLI tools". Conclusion up front: it's **not** a diff-prettifier, it's a token-cost compressor. Different problem.

This doc captures the full evaluation so we don't re-investigate next time RTK trends.

## What rtk is

[`rtk-ai/rtk`](https://github.com/rtk-ai/rtk) — Rust-written CLI proxy that intercepts shell commands invoked by LLM coding agents and rewrites them through filtering / dedup / truncation wrappers, claiming **60-90% token reduction** on common dev commands. Single static binary, no runtime deps.

**Distribution**: `brew install rtk` (Homebrew core formula), curl-installer to `~/.local/bin`, `cargo install --git`, or pre-built release binaries.

**How it integrates**: per-agent hook installation via `rtk init`. Each agent has its own hook surface:

| Agent | Hook surface |
|---|---|
| Claude Code | `PreToolUse` Bash hook in `~/.claude/settings.json` |
| Cursor | `preToolUse` in `~/.cursor/hooks.json` |
| Gemini CLI | `BeforeTool` hook |
| Codex (OpenAI) | `AGENTS.md` + `RTK.md` instructions (no hook API) |
| OpenCode | TypeScript plugin (`tool.execute.before`) |
| Windsurf | `.windsurfrules` (project-scoped, not global) |
| Cline / Roo Code | `.clinerules` (project-scoped) |
| GitHub Copilot CLI | PreToolUse deny-with-suggestion (CLI limitation — no transparent rewrite) |
| Kilo Code, Antigravity | `.kilocode/rules/` / `.agents/rules/` (project-scoped) |
| OpenClaw | TypeScript plugin |
| Mistral Vibe | Planned ([upstream #800](https://github.com/rtk-ai/rtk/issues/800)) — blocked |

**Maturity**: 44k stars, 152 releases, currently `v0.39.0` (2026-05-06, ~6 days before this eval). 3 core contributors. Apache 2.0. Active.

**Telemetry**: opt-in (GDPR Art. 6/7 consent flow), salted device hash, command counts + token-saved aggregates. `RTK_TELEMETRY_DISABLED=1` hard-disables regardless.

## Relevance to the original question

The trigger question was *"chezmoi diff 的 delta 輸出對 agent 不友善"*. **RTK does not solve this**:

- The supported-commands list (`rtk ls`, `rtk read`, `rtk grep`, `rtk find`, `rtk diff`, `rtk git ...`, `rtk gh ...`, `rtk jest/vitest/pytest/cargo`, `rtk docker`, `rtk kubectl`, `rtk aws ...`) does **not** include `chezmoi`.
- For unrecognised commands RTK passes through unmodified — the side-by-side delta output reaches the agent unchanged.
- To get RTK filtering on `chezmoi diff` we'd have to write a custom TOML filter (RTK's per-project DSL). Effort comparable to writing the wrapper script proposed in [`chezmoi-diff-pager-agent.md`](chezmoi-diff-pager-agent.md), with much more attack surface.

So as a fix for the chezmoi-diff trigger, RTK is **misaligned**. The wrapper script wins on simplicity.

What RTK *would* help with: token cost on the commands it does filter (`git status`, `cargo test`, `pytest`, etc.) when those are invoked inside long agent sessions. That's a separate question.

## Risks

Ranked by severity for *this* repo's invariants and workflow:

### 1. Pitfalls knowledge base relies on verbatim error strings (HIGH)

`pitfalls/` is symptom-grep-able **by hard rule** ([AGENTS.md](../AGENTS.md) → "Long-term backlog + past pitfalls"): titles match symptoms, error messages copy-pasted verbatim never paraphrased. The whole point is `rg "could not open a new TTY" pitfalls/` returns the right doc on second occurrence.

RTK rewrites command output: dedupes repeated lines with counts, truncates, groups errors by file/rule, drops "noise". When a bug recurs, the agent's stderr capture under RTK can disagree with the verbatim string we recorded → grep miss → re-debug from scratch. The exact failure mode this knowledge harness was designed to prevent.

This is the single biggest reason to defer.

### 2. Hook maintenance across agent matrix (HIGH)

This repo touches at least Claude Code + OpenCode (visible from this conversation), with Codex, Cursor, Antigravity all managed via `modify_*` overlays at [AGENTS.md](../AGENTS.md) → "`modify_` and `create_` prefix semantics". Adopting RTK fleet-wide means:

- `rtk init -g` on every agent. Each agent has its own hook surface (`~/.claude/settings.json` / `~/.cursor/hooks.json` / OpenCode plugin file / etc.).
- The Claude side collides with our existing `dot_claude/modify_settings.json` jq-overlay design — which is **already** dual-source-of-truth with [CodeIsland](https://github.com/wxtsky/CodeIsland)'s auto-installed hook entries (per AGENTS.md → "agent-overlays.md ... Claude hook-aware merger that lets our overlay coexist"). Adding a third source (RTK's hook) means the merger needs a third allowlist branch, and any RTK hook-format breaking change forces a merger update.
- New agents (Mistral Vibe, future ones) need RTK support upstream first, then a chezmoi role update. Lag between agent release and RTK support = configuration drift.

### 3. Reproducibility / debugging asymmetry (MEDIUM)

When a user runs `git status` directly vs. when an agent runs it under RTK's hook, output differs. Cross-host bug reports get harder ("on my machine the agent saw X, on yours Y") because RTK adds a per-host transformation layer. Mitigation: `rtk gain --history` lets you replay, but it's another tool to learn.

### 4. 0.x version velocity (MEDIUM)

39 minor releases in ~3 months. SemVer 0.x explicitly permits breaking changes per minor. Expect hook-format churn. For a fleet config repo, that means we'd need to pin the brew version + accept manual upgrade gating.

### 5. Windows native lacks hook support (LOW for this fleet)

Native Windows falls back to `CLAUDE.md`-injection mode (RTK README: "the auto-rewrite hook requires a Unix shell"). The current fleet has no Windows-native hosts (WSL only, where RTK works fully), so this is a forward-looking risk only. Worth noting if Windows enters scope.

### 6. Telemetry supply-chain footprint (LOW)

Opt-in, hashed, aggregate, `RTK_TELEMETRY_DISABLED=1` honoured. Acceptable if we explicitly set the env var in `dot_config/shell/` to make the disable fleet-wide and machine-readable. Still: another package the fleet trusts. Apache 2.0, 3 core contributors — small attack surface but non-zero.

### 7. ROI vs. observed token pain (LOW–MEDIUM judgement call)

The trigger that prompted this whole investigation is `chezmoi diff` readability, not agent token cost per se. The user's typical pain pattern (from this and adjacent conversations) is **occasional verbose output corrupting agent reasoning**, not **30-min sessions running into token-budget walls**. RTK's value proposition is the latter. Wrong tool for the observed pain.

## When to re-evaluate

Promote this from `P? declined` back to active consideration when **any** of:

- RTK ships v1.0 (signals API stability, slows breaking-change cadence)
- A native filter for `chezmoi` lands upstream (would mean the repo's own primary tool benefits without us writing a custom DSL filter)
- The fleet observes a concrete token-budget exhaustion event in an agent session (i.e., the pain shape RTK actually targets)
- A second agent on the fleet beyond Claude Code + OpenCode needs token management — sufficient agent fan-out to justify centralising compression
- The pitfalls/ grep-based reverse lookup proves robust enough that the verbatim-string risk #1 is no longer load-bearing (e.g., we move to semantic search) — would lower the dominant block

If none of these fire within 6 months, this doc stays declined and gets dated bumped.

## Decision

**2026-05 declined** — for now, ship the chezmoi-diff wrapper instead (separate doc, also deferred this round per user request). RTK solves a real problem but not the one observed here, and Risk #1 (pitfalls verbatim grep) is a structural conflict with this repo's knowledge harness as currently designed.

If the fleet starts running long-horizon agent sessions where token cost is the bottleneck rather than output readability, revisit. Until then, the targeted per-tool wrappers (chezmoi diff fallback, future ones if needed) give 80% of the value at 5% of the integration cost.

## References

- Upstream repo: <https://github.com/rtk-ai/rtk>
- Supported agents matrix: <https://www.rtk-ai.app/guide/getting-started/supported-agents>
- Configuration reference: <https://www.rtk-ai.app/guide/getting-started/configuration>
- Telemetry policy: <https://github.com/rtk-ai/rtk/blob/master/docs/TELEMETRY.md>
- Sibling decision in this repo: [`chezmoi-diff-pager-agent.md`](chezmoi-diff-pager-agent.md) — the originating question RTK was floated to answer
- Cross-cut with this repo's invariants: [`AGENTS.md`](../AGENTS.md) → "Long-term backlog + past pitfalls" (verbatim-error rule), "`modify_` and `create_` prefix semantics" (Claude/Codex/OpenCode/Cursor overlay surface)
