# Codex status line

Codex now uses its built-in TUI footer; no fork or PATH shim is installed.
Chezmoi merges this provider-neutral list into `~/.codex/config.toml` while
preserving project trust, providers, plugins, and other live settings:

```toml
[tui]
status_line = [
  "model-with-reasoning",
  "fast-mode",
  "git-branch",
  "context-remaining",
  "task-progress",
  "current-dir",
]
```

Run `/status` when you need authoritative routing details. In a
`codex-copilot` session it should show the localhost model provider even if the
Account line still shows the logged-in ChatGPT account; that account is UI/auth
state, not evidence that inference bypassed the proxy.

## Why the quota fields are absent

Codex also offers `five-hour-limit` and `weekly-limit`, but those counters can
still describe the ChatGPT account when a one-shot launcher changes only the
model provider. Showing them beside Copilot inference would be ambiguous, so the
managed footer sticks to provider-neutral facts. [CodexBar](codexbar.md) remains
the complementary menu-bar view for account usage.

## Why not a Claude-HUD-style extension?

Stock Codex accepts a fixed list of status item IDs; it does not run an
arbitrary status command or support custom ANSI/conditional rendering. The
third-party `@jiawang1209/codex-hud` can emulate Claude HUD only by patching and
compiling an older Codex Rust tree and placing a shim ahead of the official
binary. That upgrade and supply-chain surface is not worthwhile for a footer,
so it is documented but intentionally not installed.

`codex_apps` is unrelated to the footer and unrelated to Codex.app. It is a
remote ChatGPT MCP route at `https://chatgpt.com/backend-api/wham/apps`; the CLI
can use it on Intel or Apple Silicon. `copilot-proxy doctor --live` probes that
route directly and through the detected HTTP proxy, separately from localhost
Copilot inference.

References: [Codex configuration](https://developers.openai.com/codex/config-reference),
[fixed status-item limitation](https://github.com/openai/codex/issues/20244),
[custom status-line request](https://github.com/openai/codex/issues/17827).
