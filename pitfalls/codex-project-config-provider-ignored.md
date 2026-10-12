# Project config parses successfully but Codex still uses the original provider

**Symptoms**: `Ignored unsupported project-local config keys`; project
`model_provider` / `model_providers` have no effect although `debug models` succeeds.
**First seen**: 2026-09
**Affects**: Codex CLI 0.156.1, observed on macOS arm64
**Status**: version-specific limitation; use invocation-level overrides, retest after upgrades

## Symptom

A trusted temporary Git project contained a custom provider pointing at a local
mock endpoint. `codex debug models --bundled` returned JSON successfully.
An actual `codex exec --ephemeral --json` launch never reached that endpoint and
emitted this exact warning (the temporary test path is retained for searchability):

```text
Ignored unsupported project-local config keys in /private/var/folders/xz/b1n4y0mn3lj6qs5ydgypj2r80000gn/T/tmp90_yrmqh/project/.codex/config.toml: model_provider, model_providers. If you want these settings to apply, manually set them in your user-level config.toml.
```

It then attempted the original OpenAI provider. No real credentials or user
configuration were used in the probe.

## Root cause

Project config support does not mean every configuration key is allowed at that
scope. The CLI filters provider selection/definitions as host-owned settings.
A bundled-model catalog dump is not a runtime routing check, so it supplied
misleading confidence during planning.

Claude's `.claude/settings.local.json` is also not an exact analogue of Codex's
project config: Codex has no separate `config.local.toml` override layer.

## Workaround

Use `codex-copilot-once` (or its identical `codex-copilot` spelling). It supplies
the provider with invocation-level `-c` options and leaves ordinary new Codex /
SpecStory launches on their existing provider. `copilot-here codex on` explains
the limitation and does not write an ineffective pin or modify user-wide routing.

Keep legitimate shared project configuration available for version control.
Ignoring a tracked file does not make a private provider overlay safe.

## Prevention and upgrade retest

This is **not** a permanent claim that Codex can never support project providers.
Before implementing a persistent Codex project pin after an upgrade:

1. Record the exact CLI version and use isolated HOME, CODEX_HOME and Git project
   directories; explicitly trust only that temporary project's canonical path.
2. Put the provider definition/selection only in the project's config.
3. Use dummy credentials and a localhost mock, with outbound network blocked.
   Run an actual foreground session; a parser/catalog-only check is insufficient.
4. Confirm the mock receives the request and the unsupported-key warning is gone.
5. Check ordinary startup and resume separately, plus ignored/untracked and
   tracked project config handling. Stop the entire owned test process group.

Only then reconsider the project pin. Existing launcher behavior does not depend
on this unsupported scope.

## Related

- [Copilot guide](../docs/tools/copilot-claude-proxy.md)
- [Codex configuration basics](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Thread resume provider registration](codex-thread-resume-provider-not-found.md)
