# claude-hud statusline shows the raw model id (`claude-opus-5[1m]`) instead of a friendly name

**Symptoms** (grep this section):
- The claude-hud statusline shows the literal pinned model string —
  `claude-opus-5[1m]`, `claude-opus-4-8[1m]` — with the `[1m]` suffix visible,
  instead of a readable name like `Opus 5 (1M context)`
- **The same dotfiles config renders differently on two machines** — friendly
  name on one host, raw id on another, with identical
  `.claude/settings.local.json` and identical chezmoi-managed claude-hud config
- No error anywhere; `claude --version` works, the statusline renders fine
  otherwise, and the model itself works (requests succeed)
- Possibly alongside: context percentage in the HUD climbing ~5× faster than
  expected, or exceeding 100%

**First seen**: 2026-07
**Affects**: claude-hud (any version — the fallback is by design), Claude Code
older than ~2.1.220, any model id carrying the Claude Code-only `[1m]` suffix
**Status**: not a bug in claude-hud or the pin — fixed by upgrading Claude Code
on the lagging host

## Symptom

Two machines, same chezmoi-managed dotfiles, same project pin
(`ANTHROPIC_MODEL = "claude-opus-5[1m]"` in `.claude/settings.local.json`):

| Host | Claude Code | statusline shows |
|---|---|---|
| macOS | 2.1.220 | `Opus 5 (1M context)` |
| Ubuntu | 2.1.207 | `claude-opus-5[1m]` |

## Root cause

The friendly name is **not** computed by claude-hud — it comes from the
`model.display_name` field that **Claude Code** puts in the statusline JSON it
pipes to the statusline command. claude-hud's `getModelName()`
(`~/.claude/plugins/cache/claude-hud/claude-hud/<ver>/src/stdin.ts`) is:

```ts
const displayName = stdin.model?.display_name?.trim();
if (displayName) return displayName;          // "Opus 5 (1M context)"
const modelId = stdin.model?.id?.trim();
if (!modelId) return 'Unknown';
return normalizeBedrockModelLabel(modelId) ?? modelId;   // "claude-opus-5[1m]"
```

So **seeing the raw id means `display_name` was absent or empty** — the raw id
is the fallback branch, not a formatting choice.

Why it's absent: `[1m]` is a Claude Code-only suffix, not a real API model id.
Claude Code has to strip it and match the remainder against its built-in model
table to produce a display name (and to size the context window). A Claude Code
old enough to predate the model in that table matches nothing, so it emits no
`display_name` — and claude-hud falls back.

This is the same table-matching mechanism behind the older "dotted ids cause the
`[Opus 4] retired` warning and a >100% context HUD" gotcha in
[`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md) —
different trigger (stale binary vs wrong id shape), identical failure path.

## Why it can be more than cosmetic

claude-hud reads the context window size **straight from Claude Code** — it does
not infer it from the model id:

```ts
const size = stdin.context_window?.context_window_size;
```

If the same unrecognized-model condition also makes Claude Code assume a 200k
window for a model that actually serves 1M, the HUD's context percentage runs
~5× high and compaction triggers on the wrong budget. Treat a raw-id statusline
as a signal to check the context percentage too, not just a cosmetic annoyance.

## Fix

Upgrade Claude Code on the lagging host:

```sh
ssh <host> 'claude update'
# or, through this repo's upgrade path (justfile → cat_agents → `claude update`)
just upgrade-agents
```

## Why `chezmoi apply` / `fleet-apply` does not fix it

By design — see AGENTS.md → "Install vs upgrade is split on purpose". `chezmoi
apply` and ansible are install-only (`state: present`, `creates:`), so a host
that already has *some* `claude` binary is never bumped by an apply. Version
drift across the fleet accumulates silently until something like this surfaces
it, and `just upgrade-*` has to be run **on each host** — `fleet-apply` does not
broadcast upgrades.

Consequence for debugging: "same config, different behavior across machines" is
much more often a **binary version skew** than a config-drift problem in this
repo. Check `claude --version` (or the equivalent) on both hosts before
diffing configs.

`claude` is not on the non-interactive SSH PATH on Linux — a bare
`ssh host 'claude --version'` returns `claude: not on PATH` even though it is
installed at `~/.local/bin/claude`. Augment PATH, or use `fleet exec`, which
carries the PATH prelude for exactly this reason (see
[`docs/tools/fleet-exec.md`](../docs/tools/fleet-exec.md)).

## Related

- [`claude-hud-usage-statusline-stale`](claude-hud-usage-statusline-stale.md)
- claude-hud's config is chezmoi-managed — live edits get reverted on apply; see
  [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md)
