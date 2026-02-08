# CodexBar CLI

[CodexBar](https://github.com/steipete/CodexBar) shows usage stats for AI coding tools (Codex, Claude Code, Cursor, Gemini, Copilot, etc.) without logging into each dashboard.

- **macOS**: Full menu bar app + CLI
- **Linux**: CLI only

## Installation

Installed automatically via the `coding_agents` ansible role. On Linux, the binary is placed at `~/.local/bin/codexbar`.

## Linux Usage

On Linux, you **must** pass `--source cli` for the `usage` command. The default source (`auto`/`web`) is macOS-only.

### Check live usage (rate limits / quotas)

```bash
# Claude session/weekly limits
codexbar usage --provider claude --source cli

# Other providers
codexbar usage --provider codex --source cli
codexbar usage --provider gemini --source cli
codexbar usage --provider copilot --source cli

# JSON output (for scripting / Waybar)
codexbar usage --provider claude --source cli --json --pretty
```

Example output:

```
== Claude 2.1.34 (claude) ==
Session: 14% left [=-----------]
```

### Check local cost (from JSONL logs, no auth needed)

The `cost` command reads local log files (e.g. `~/.claude/`) and doesn't require auth.

```bash
# All providers
codexbar cost

# Claude only
codexbar cost --provider claude

# JSON output
codexbar cost --provider claude --json --pretty

# Force rescan of logs
codexbar cost --refresh
```

Example output:

```
Claude Cost (local)
Today: $0.54 · 851K tokens
Last 30 days: $8.50 · 9.1M tokens
```

## Shell Aliases

Defined in `~/.config/zsh/tools/40_codexbar.zsh`:

| Alias | Command | Description |
|-------|---------|-------------|
| `cbu` | `codexbar usage --provider claude --source cli` | Claude usage |
| `cbc` | `codexbar cost --provider claude` | Claude local cost |
| `cbca` | `codexbar cost` | All providers local cost |

## Supported Providers

`codex`, `claude`, `cursor`, `opencode`, `factory`, `gemini`, `antigravity`, `copilot`, `zai`, `minimax`, `kimi`, `kiro`, `vertexai`, `augment`, `jetbrains`, `kimik2`, `amp`

## Tips

- Avoid `--provider all` with `usage` on Linux -- it tries each provider sequentially and can hang if a CLI isn't installed.
- The `cost` command works offline by scanning local JSONL log files.
- The `usage --source cli` command invokes the provider's CLI (e.g. `claude`) to get live rate-limit data.
- Config file: `~/.codexbar/config.json`
