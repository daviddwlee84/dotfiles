# ChatGPT cannot resume a Codex thread: Model provider `copilot_api` not found

**Symptoms**: `ChatGPT can't load config.toml, so this thread can't resume.`;
`Fix config.toml: Model provider \`copilot_api\` not found. After saving the file, reopen the thread.`
**First seen**: 2026-09
**Affects**: Codex CLI 0.153.4 and GUI resumes of `codex-copilot` threads
**Status**: fixed locally; missing provider is seeded by the Codex config merger

## Symptom

Threads launched with `codex-copilot` work, but reopening them in ChatGPT fails:

```text
ChatGPT can't load config.toml, so this thread can't resume.
Fix config.toml: Model provider `copilot_api` not found. After saving the file, reopen the thread.
```

## Root cause

The launcher supplies the provider definition through process-local `-c`
arguments. The thread records `copilot_api`; the next process must resolve
that ID from its own config. This host had no `[model_providers]` table.
Persisting only `env_key = "GITHUB_COPILOT_API_KEY"` would introduce another
failure because GUI processes need not inherit the launcher's dummy env key.

## Workaround

Apply the managed user config, then reopen the thread. The merger registers
`copilot_api` with the default local shim URL and a literal dummy bearer.
It leaves `model_provider` unchanged and preserves existing custom provider
tables. A custom gateway port must also be reflected in the persisted table.

On the incident host, only the provider table was appended after a backup;
full apply also wanted to change an unrelated live reasoning preference.

## Prevention

`tests/unit/agent_overlays.bats` covers seeding, idempotence, unchanged default
selection, and preservation of existing provider/auth/port settings.
Validate provider resolution with the real app:

```sh
env -u GITHUB_COPILOT_API_KEY codex debug prompt-input \
  -c 'model_provider="copilot_api"' 'configuration validation only' >/dev/null
```

`codex debug models --bundled` is insufficient: it succeeded even when this
provider was missing. The prompt-input command reproduced the exact error.

## Related

- [Codex configuration reference](https://developers.openai.com/codex/config-reference/)
- [Gateway documentation](../docs/tools/copilot-claude-proxy.md)
