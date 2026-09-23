# Codex uses 872k context and compacts at 784,800 despite a 1M override

**Symptoms** (grep this section): `model_context_window=1000000`; `model_auto_compact_token_limit=872000`; effective context remains `872000`; compact limit becomes `784800`; Copilot advertises a one-million-token context; GPT-6 Sol/Luna still use smaller bundled limits
**First seen**: 2026-09-23
**Affects**: Codex CLI 0.156.1 through `codex-copilot` with an unchanged bundled model catalog
**Status**: fixed in the Unix/Windows launchers with provider-derived model descriptors; verified without inference

## Symptom

The launcher supplied both `model_context_window=1000000` and
`model_auto_compact_token_limit=872000` for `gpt-6-sol`, matching the live Copilot
catalog. Those arguments alone did not produce a one-million-token model context:
the effective context was capped at 872,000 and the compact limit at 784,800.
This is a silent clamp, not an upstream context-overflow error.

The installed binary reveals the conflicting descriptor without an inference
request:

```sh
codex debug models --bundled |
  jq '.models[] | select(.slug == "gpt-6-sol") |
      {slug, context_window, max_context_window, effective_context_window_percent}'
```

Observed with Codex 0.156.1:

```json
{
  "slug": "gpt-6-sol",
  "context_window": 272000,
  "max_context_window": 872000,
  "effective_context_window_percent": 95
}
```

`gpt-6-luna` has the same bundled context/max-context pair. These are Codex's
bundled descriptors, not evidence that Copilot serves the same limits.

## Root cause

Codex applies a configured context override as
`min(model_context_window, descriptor.max_context_window)`. The bundled Sol/Luna
maximum is 872,000, so a one-million override is reduced before use. It then caps
auto-compact at 90% of that full model context: `min(872000, 0.9 × 872000)` is
784,800. Usable input is a separate calculation, defaulting to 95% of context.
Multiplying the usable value by 90% again is incorrect.

The source references are
[the context override clamp](https://github.com/openai/codex/blob/rust-v0.156.1/codex-rs/models-manager/src/model_info.rs#L19-L31),
[Sol's bundled descriptor](https://github.com/openai/codex/blob/rust-v0.156.1/codex-rs/models-manager/models.json#L174-L205),
[Luna's bundled descriptor](https://github.com/openai/codex/blob/rust-v0.156.1/codex-rs/models-manager/models.json#L346-L377),
and [the usable-context/compact calculations](https://github.com/openai/codex/blob/rust-v0.156.1/codex-rs/protocol/src/openai_models.rs#L513-L535).

## Workaround

Deploy the updated launcher and start a new session:

```sh
codex --version                    # 0.156.1 or newer for GPT-6 Sol/Luna descriptors
codex-copilot -m gpt-6-sol
```

The launcher starts from the installed binary's `codex debug models --bundled`
catalog, finds exact model IDs in the same live Copilot snapshot used for model
selection, and changes only `context_window` and `max_context_window` to the
live context value. It preserves reasoning, tool capabilities, prompts and all
other bundled metadata. It never substitutes Astra's or an older Sol descriptor
for a missing GPT-6 Sol/Luna descriptor; that case requires upgrading Codex.

The validated catalog is published atomically under
`$XDG_CACHE_HOME/copilot-proxy/codex-models/` (default
`~/.cache/copilot-proxy/codex-models/`). Its identity includes the Codex version,
cache schema and canonical model-to-context-map hash. Prompt/output values are
not part of that hash: the launcher recalculates the compact override on each
launch. It leaves `~/.codex/models_cache.json` alone.

A caller-supplied `-c model_catalog_json=...` skips this generation entirely; the
caller then owns descriptor correctness. Raising `model_context_window` while
retaining a smaller `max_context_window` in that custom file reproduces the trap.

The 2026-09-23 live snapshot and corrected calculations were:

| Model | Provider context | Prompt ceiling | Max output | Codex usable context (95%) | Effective compact trigger |
|---|---:|---:|---:|---:|---:|
| `gpt-6-sol` / `gpt-6-luna` | 1,000,000 | 872,000 | 128,000 | 950,000 | 872,000 |
| `gpt-6-astra` | 1,050,000 | 1,050,000 | 128,000 | 997,500 | 735,000 |

Sol/Luna use the full live prompt budget; Astra retains its separate 70% policy.
Codex's actual compact trigger is the smaller of the launcher budget and 90% of
the full context. Explicit provider prompt metadata is authoritative; subtract
maximum output only when that prompt field is absent. These observed limits may
change by account or rollout.

## Prevention

- Test the real Codex catalog parser and effective calculations, not only captured
  launcher arguments. Correct argv does not prove the model accepted those limits.
- Keep exact descriptor matching and change only the two context fields; context
  support does not justify inventing reasoning/tool capabilities.
- Keep cache invalidation tied to live context changes as well as CLI/schema
  versions, and test both raw and SpecStory launch paths.
- Recompute at launch and refresh managed pins deliberately; do not rewrite saved
  conversation history to make its old limits look current.

## Related

- [Missing model metadata after a Copilot refresh](codex-model-metadata-not-found-after-copilot-refresh.md) — the earlier reason to isolate the catalog from Codex's provider-global cache.
- [Astra remote compact 408, then success](codex-astra-remote-compact-408-then-succeeds.md) — a separate request-body timeout; correcting context metadata does not establish a transport fix.
- [Copilot gateway guide](../docs/tools/copilot-claude-proxy.md)
- [Codex 0.156.1 release](https://github.com/openai/codex/releases/tag/rust-v0.156.1)
