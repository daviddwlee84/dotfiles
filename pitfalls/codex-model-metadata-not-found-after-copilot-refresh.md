# Codex warns "Model metadata for `gpt-5.6-sol` not found" after using the Copilot gateway

**Symptoms** (grep this section): `Model metadata for gpt-5.6-sol not found`; `Defaulting to fallback metadata; this can degrade performance and cause issues.`; the model still answers successfully; `codex debug models --bundled` contains the model but normal `codex debug models` does not; `~/.codex/models_cache.json` contains only Copilot adapter models such as `gemini-3.1-pro-preview`
**First seen**: 2026-08
**Affects**: Codex CLI 0.147.0 with a custom `copilot-api` provider; observed with `@jeffreycao/copilot-api` 2.1.0
**Status**: fixed locally in `codex-copilot` with a versioned bundled `model_catalog_json` override plus live gateway token limits

## Symptom

```
⚠ Model metadata for `gpt-5.6-sol` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
```

The warning is misleading as a model-availability signal: the same session can
send `POST /responses` with `model: gpt-5.6-sol` and receive HTTP 200 responses.

Reproduction:

1. Start the Copilot gateway and run `codex-copilot` with `gpt-5.6-sol`.
2. Let Codex refresh `/models?client_version=0.147.0` through the custom provider.
3. Observe that `~/.codex/models_cache.json` has only a small adapter subset.
4. Start another session and observe the fallback-metadata warning.

Useful comparison:

```sh
codex debug models --bundled | jq -r '.models[].slug' | grep gpt-5.6-sol
codex debug models           | jq -r '.models[].slug' | grep gpt-5.6-sol
```

The first command finds Sol while the second can return nothing.

## Root cause

Codex uses one global `~/.codex/models_cache.json`; the cache is not namespaced
by `model_provider`. A custom-provider model refresh can therefore replace the
first-party catalog with the subset Codex derives from the Copilot gateway.

In the observed case the gateway's raw `/models` response contained 17 entries,
including `gpt-5.6-sol`, but Codex persisted only three Gemini adapter records.
That provider-global cache then took precedence over the model metadata bundled
inside the same Codex 0.147.0 binary.

Deleting `~/.codex/models_cache.json` appears to fix the next launch but is not
durable: another custom-provider refresh can recreate the degraded cache.

## Workaround

`codex-copilot` generates the installed binary's bundled catalog once per Codex
version:

```sh
codex debug models --bundled \
  > ~/.cache/copilot-proxy/codex-models/codex-cli_0.147.0.json
```

It then prepends this per-process override:

```toml
model_catalog_json = "~/.cache/copilot-proxy/codex-models/codex-cli_0.147.0.json"
```

The launcher also passes the selected model's live
`model_context_window` and `model_auto_compact_token_limit` from the gateway,
because bundled limits can lag Copilot's entitlement-specific long-context
values. Explicit user `-c` arguments remain later in argv and still win.

## Prevention

- Keep `_copilot_codex_catalog_file` version-keyed and validate `.models` before
  atomically replacing its cache file.
- Do not "fix" this by deleting `~/.codex/models_cache.json` on every launch;
  plain Codex owns that cache and other providers may need it.
- Keep the live token-limit injection paired with the bundled catalog override.
- Regression coverage lives in `tests/unit/copilot_proxy.bats`.

## Related

- `dot_config/shell/43_copilot_proxy.sh`
- `docs/tools/copilot-claude-proxy.md`
- `pitfalls/copilot-api-caches-degraded-model-list-at-startup.md`
- Codex configuration reference: <https://developers.openai.com/codex/config-reference>
