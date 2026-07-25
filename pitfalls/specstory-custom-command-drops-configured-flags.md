# Passing args to a specstory-wrapped agent silently drops `claude_cmd` flags → session lands in the wrong permission mode

**Symptoms** (grep this section):
- `claude-copilot-once` (no args) starts Claude Code in **bypass-permissions**
  mode, but `claude-copilot-once --resume <id>` starts in **`auto`** mode —
  same wrapper, same project, same shell, opposite behaviour
- Claude Code shows the permission prompt / `⏵⏵ auto-accept edits off` banner
  only when you pass arguments
- `/status` inside the session reports the permission mode coming from
  `~/.claude/settings.json` (`permissions.defaultMode`) instead of the
  `--dangerously-skip-permissions` you configured in specstory
- Nothing is logged, nothing warns, and `specstory check claude` reports
  `✅ All systems go!` in both cases
- Applies equally to any other flag in `claude_cmd` (`--model`, `--add-dir`, …)
  and to the sibling `codex_cmd` / `cursor_cmd` / `droid_cmd` / `gemini_cmd`
  entries

**First seen**: 2026-07
**Affects**: specstory CLI 2.5.0 (`specstory run <provider> -c …`);
`claude-copilot` / `claude-copilot-once` in `dot_config/shell/43_copilot_proxy.sh`
**Status**: by-design upstream; fixed locally in `43_copilot_proxy.sh`

## Symptom

With this in `~/.specstory/cli/config.toml`:

```toml
[providers]
claude_cmd = "claude --dangerously-skip-permissions"
```

these two commands run in **different permission modes**:

```sh
claude-copilot-once                   # bypass permissions  ✅
claude-copilot-once --resume <id>     # auto (the ~/.claude default)  ❌
```

## Root cause

specstory's `-c/--command` **replaces** the provider's configured command; it
does **not** append to it. The two are the same slot — the shipped config file
says so in its own comment:

> Agent execution commands by provider (used by `specstory run`).
> Pass custom flags (e.g. `claude_cmd = "claude --allow-dangerously-skip-permissions"`).
> **Use of these is equivalent to `-c "custom command"`.**

`claude-copilot` used to branch like this:

```sh
if [ "$#" -gt 0 ]; then
  copilot-run specstory run claude -c "claude $*"   # ← clobbers claude_cmd
else
  copilot-run specstory run claude                  # ← claude_cmd applies
fi
```

So the *presence of arguments* silently decided whether your configured flags
were honoured. The no-arg path never passes `-c`, so `claude_cmd` wins; the
moment you pass anything through, the hardcoded bare `claude` in the `-c` string
becomes the entire command and every configured flag is gone. Claude Code then
falls back to `~/.claude/settings.json`'s `permissions.defaultMode` (`"auto"`
in this repo), which is exactly what the user observes.

Verified with a fake agent that logs its own argv:

```
# specstory run claude                       (claude_cmd = "<fake> --from-config")
ARGV: --from-config
# specstory run claude -c "<fake> --resume abc123"
ARGV: --resume abc123          ← --from-config is gone, not merged
```

## Fix

Rebuild the base command from specstory's own config instead of hardcoding
`claude`, so the config stays the single source of truth for **both** branches.
`_copilot_specstory_claude_cmd` in `dot_config/shell/43_copilot_proxy.sh` reads
the effective `claude_cmd` honouring specstory's precedence (project
`./.specstory/cli/config.toml` > user `~/.specstory/cli/config.toml` > bare
`claude`), and `claude-copilot` appends the passthrough args to it.

Two non-obvious constraints in that helper:

- **Skip commented lines.** Both shipped configs carry a commented
  `# claude_cmd = "claude"` example. A naive `grep claude_cmd` matches the
  project-level comment first and pins a bare `claude` — re-introducing the very
  bug it is meant to fix.
- **Quote each passthrough arg.** specstory shell-splits the `-c` string
  honouring quotes (`-p 'a b'` arrives as one argv entry), so the old
  `"claude $*"` also flattened `claude-copilot -p "two words"` into two separate
  arguments. Each arg is now single-quoted with the POSIX `'\''` escape.

## Why not fix it the other two ways

- **Change `~/.claude/settings.json` → `defaultMode: "bypassPermissions"`.**
  That file is chezmoi-managed and global, so it would put *every* Claude Code
  session on every project into bypass mode — including plain `claude` on the
  real Anthropic backend, which is far more blast radius than the copilot
  wrappers asked for.
- **Hardcode `--dangerously-skip-permissions` into the shell function.** Splits
  the source of truth in two: the specstory config would silently stop being
  authoritative for the args path, and the next person to edit `claude_cmd`
  would be baffled again.

## Related

- [`copilot-api-caches-degraded-model-list-at-startup`](copilot-api-caches-degraded-model-list-at-startup.md)
- [`docs/tools/copilot-claude-proxy.md`](../docs/tools/copilot-claude-proxy.md)
