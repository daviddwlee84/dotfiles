# SpecStory CLI

`SpecStory` records terminal coding-agent sessions and can wrap supported agents with `specstory run`.

## Installation in This Dotfiles Repo

`specstory` is installed automatically by the `coding_agents` ansible role.

- macOS: Homebrew preferred, with a GitHub release fallback to `~/.local/bin`
- Linux: GitHub release tarball installed to `~/.local/bin`

## Global vs Project Config

This dotfiles repo manages the user-level SpecStory config at `~/.specstory/cli/config.toml`.

SpecStory reads configuration in this order:

1. User-level config: `~/.specstory/cli/config.toml`
2. Project-level config: `./.specstory/cli/config.toml`
3. CLI flags passed to `specstory`

Later sources override earlier ones. That means the dotfile provides global defaults, while a repo-specific `.specstory/cli/config.toml` can override them when a project needs different behavior.

!!! note "Seeded once, not continuously managed"
    The user-level config is a chezmoi `create_` file (`private_dot_specstory/private_cli/create_config.toml`): chezmoi writes it on first `apply` and then **never touches it again**. This is deliberate — the SpecStory CLI writes runtime UI state back into the file (e.g. a `[resume]` block with `view_mode` / `last_agent` after `specstory resume`), which would otherwise show up as permanent chezmoi drift. To change the shipped defaults, edit the source and re-seed: `cp ~/.specstory/cli/config.toml "$(chezmoi source-path ~/.specstory/cli/config.toml)"`.

## Managed Defaults

The managed config keeps the upstream sample sections as commented documentation, but only enables `[providers]` defaults.

Configured providers:

- `antigravity_cmd = "agy --dangerously-skip-permissions"`
- `claude_cmd = "claude --dangerously-skip-permissions"`
- `codex_cmd = 'codex -c model_reasoning_effort="high" --ask-for-approval never --sandbox danger-full-access -c model_reasoning_summary="detailed" -c model_supports_reasoning_summaries=true'`
- `cursor_cmd = "cursor-agent --force"`
- `droid_cmd = "droid --yolo"`
- `gemini_cmd = "gemini --sandbox=none"`

These are the commands `specstory run claude`, `specstory run codex`, and similar provider shortcuts will execute by default unless overridden per project or on the command line.

### Always name the provider — the no-arg default is not stable

`<id>_cmd` controls **how** a provider launches, never **which** one bare `specstory run` picks. There is no `default_provider` key: with no argument, specstory resolves to the **alphabetically-first** entry of its provider registry. Adding `antigravity` in 2.9.0 therefore silently displaced `claude` as the default on every existing install, and `specstory run --help` re-generated itself to match (`By default, launches Antigravity CLI.`). Since `agy` was installed, the wrong agent launched successfully with no error.

Always write `specstory run claude`. This repo's wrappers do — see `_sesh_wrap_agent()` in `dot_config/shell/22_sesh.sh` (shared by `scode` / `svibe` / `hcode` / `hvibe`) and [pitfalls/specstory-run-default-agent-drift.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/specstory-run-default-agent-drift.md).

## Safety Tradeoff

The configured provider commands intentionally favor low-friction agent execution:

- Claude uses `--dangerously-skip-permissions`
- Codex uses `--ask-for-approval never` and `--sandbox danger-full-access`
- Antigravity uses `--dangerously-skip-permissions`; Cursor uses `--force` and Droid `--yolo`
- Gemini uses `--sandbox=none`

This removes most interactive permission prompts, which is useful for fast local workflows, but it also gives the wrapped agents broader filesystem or command access. Keep these defaults only if you trust the environment and want convenience over stricter guardrails. If not, override the relevant provider command in the global file, a project-local config, or the `specstory run -c ...` flag.

## Verify

```bash
specstory --version
specstory run codex --help
chezmoi diff
```

## See also

- [SpecStory internals (filename algorithm, reverse lookup, markdown structure)](specstory-internals.md) — what this repo's `tv agent-sessions` channel uses to link live sessions back to `.specstory/history/*.md`.

## References

- [SpecStory CLI usage docs](https://docs.specstory.com/integrations/terminal-coding-agents/usage#configuration)
- [SpecStory CLI releases](https://github.com/specstoryai/getspecstory/releases)
- [SpecStory CLI source on DeepWiki](https://deepwiki.com/specstoryai/getspecstory) — generated technical reference for the Go implementation.
