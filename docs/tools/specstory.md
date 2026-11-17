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

!!! note "Overlay-managed (`modify_`), not plain-managed"
    The user-level config is rendered by a chezmoi `modify_` script (`private_dot_specstory/private_cli/modify_private_config.toml.tmpl`) from the template `.chezmoitemplates/specstory/config.toml`. SpecStory is a foreign writer: `specstory resume` writes a `[resume]` table (`view_mode` / `last_agent`) back into the file, so a plain managed file would drift forever. On every `chezmoi apply`, each **active** key in the template wins; every other live key is kept: unknown tables such as `[resume]` wholesale, plus extra keys inside managed tables, for example a host-local `local_time_zone = true` under `[local_sync]`. Deleting a key from the template does **not** remove it from hosts, so set it to the value you want instead. Invalid TOML in the live file fails the apply loudly rather than being overwritten. Edit the template, never `chezmoi add` the target (that would overwrite the script). The file used to be `create_` (seed-once), which meant template updates never reached existing hosts. The `private_` attribute matches the 0600 mode SpecStory itself uses when it rewrites the file; without it, every `resume` would cause a mode drift.

## Managed Defaults

The managed config keeps the upstream sample sections as commented documentation, and enables only `[providers]` and `[redaction]` defaults.

Configured providers (every `*_cmd` key SpecStory 2.17 accepts for a local CLI):

| Key | Command | Bypass mechanism |
|---|---|---|
| `antigravity_cmd` | `agy --dangerously-skip-permissions` | auto-approve all tool requests |
| `claude_cmd` | `claude --dangerously-skip-permissions` | bypassPermissions (`--permission-mode auto` is the classifier-gated alternative) |
| `codex_cmd` | `codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_summary="detailed"` | = `-a never -s danger-full-access` |
| `copilot_cmd` | `copilot --yolo` | = `--allow-all` (tools, paths, URLs) |
| `cursor_cmd` | `cursor-agent --force` | run everything unless denied |
| `droid_cmd` | `droid --yolo` | — |
| `gemini_cmd` | `gemini --yolo` | auto-approve all tools |
| `opencode_cmd` | `opencode --auto` | auto-approve anything not explicitly denied |
| `pi_cmd` | `pi` | Pi has no permission prompts |
| `qwen_cmd` | `qwen --yolo` | auto-approve all tools |

`deepseek_cmd` / `grok_cmd` / `muse_cmd` ship commented out — their bypass flags were not verified. The IDE/cloud providers (`copilotide`, `cursoride`, `cursorcloud`) don't launch a local CLI through `run` and have no entry.

Other non-provider defaults: `[redaction] enabled = true` (pinned explicitly so an upstream default change can't silently disable secret redaction). Analytics and cloud sync are left at their upstream defaults (cloud sync, is on only when logged in to SpecStory Cloud).

These are the commands `specstory run claude`, `specstory run codex`, and similar provider shortcuts will execute by default unless overridden per project or on the command line.

Codex model and reasoning effort are deliberately **not** pinned here — they come from `~/.codex/config.toml`. Only `model_reasoning_summary="detailed"` stays, so the saved markdown keeps reasoning text. (The original seed pinned `model_reasoning_effort="high"` and the obsolete `model_supports_reasoning_summaries=true`; Codex 0.156+ reports the latter as an ignored `session-flags` setting.) Gemini used to ship `--sandbox=none`, which only controls sandboxing and never skipped approvals; `--yolo` is the actual bypass.

Existing hosts pick up template changes on the next `chezmoi apply` (or `fleet-apply`), with no manual re-seed.

### Always name the provider — the no-arg default is not stable

`<id>_cmd` controls **how** a provider launches, never **which** one bare `specstory run` picks. There is no `default_provider` key: with no argument, specstory resolves to the **alphabetically-first** entry of its provider registry. Adding `antigravity` in 2.9.0 therefore silently displaced `claude` as the default on every existing install, and `specstory run --help` re-generated itself to match (`By default, launches Antigravity CLI.`). Since `agy` was installed, the wrong agent launched successfully with no error.

Always write `specstory run claude`. This repo's wrappers do — see `_sesh_wrap_agent()` in `dot_config/shell/22_sesh.sh` (shared by `scode` / `svibe` / `hcode` / `hvibe`) and [pitfalls/specstory-run-default-agent-drift.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/specstory-run-default-agent-drift.md).

## Optional export after a Copilot session

`claude-copilot-once --specstory-mode exit` and
`codex-copilot-once --specstory-mode exit` run the agent directly and export
same-project/provider history after exit. Default `run` still records live;
`off` / `--no-specstory` skips a new recording request. Both `run` and `exit`
inherit provider commands from the real TOML configuration. Explicit caller
permissions override those defaults; the launchers supply bypass only where
no posture was chosen. See the [recording lifecycle](copilot-claude-proxy.md#recording---specstory-mode-runexitoff)
for concurrency, pending recovery and signal limitations. These helpers never
commit the export automatically.

## Safety Tradeoff

The configured provider commands intentionally favor low-friction agent execution:

- Claude and Antigravity use `--dangerously-skip-permissions`
- Codex uses `--dangerously-bypass-approvals-and-sandbox` (no approvals, no sandbox)
- Copilot, Droid, Gemini and Qwen use `--yolo`; Cursor uses `--force`; OpenCode uses `--auto`
- Pi has no permission layer at all

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
