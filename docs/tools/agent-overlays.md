# Coding-agent CLI overlays (Cursor / OpenCode / Codex)

This repo manages the *global* config files of three coding-agent CLIs via chezmoi `modify_` overlays:

| CLI | Live file | Source script | Merge engine |
|---|---|---|---|
| Cursor | `~/.cursor/cli-config.json` | [`dot_cursor/modify_cli-config.json.tmpl`](../../dot_cursor/modify_cli-config.json.tmpl) | `jq '. * $overlay'` |
| OpenCode | `~/.config/opencode/opencode.json` | [`dot_config/opencode/modify_opencode.json.tmpl`](../../dot_config/opencode/modify_opencode.json.tmpl) | `jq '. * $overlay'` |
| Codex | `~/.codex/config.toml` | [`dot_codex/modify_config.toml.tmpl`](../../dot_codex/modify_config.toml.tmpl) | Python `tomllib` + inline emitter |

Overlay payloads live under [`.chezmoitemplates/agents/`](../../.chezmoitemplates/agents/) and are sourced via `{{ template ... }}` includes so the merge logic can be tested independently of overlay contents.

## Why `modify_` and not full file management

All three CLIs **rewrite their config file at runtime** to record machine-local state: auth tokens, telemetry IDs, per-project trust grants, marketplace registrations with absolute paths, plugin-cache hashes, last-used provider hints, etc. Tracking the whole file as managed content would:

1. Leak secrets (`authInfo`, `auth.json` content) into the dotfiles repo.
2. Bake one machine's absolute paths (`/Users/me/.codex/.tmp/...`) into another machine's apply.
3. Produce constant `chezmoi diff` noise as the CLI churns the file.

The `modify_` overlay model deep-merges only the keys we explicitly enforce; everything else passes through verbatim.

## What each overlay enforces

### Cursor — [`agents/cursor.cli-config.overlay.json`](../../.chezmoitemplates/agents/cursor.cli-config.overlay.json)

```json
{
  "editor": { "vimMode": true }
}
```

- `editor.vimMode = true` — universal preference; sibling `editor.fontSize` etc. survive the deep merge.
- **`permissions` is intentionally NOT in the overlay.** `jq '. * $overlay'` replaces arrays wholesale, so listing any `permissions.allow` / `permissions.deny` entries here would clobber the user's live machine-specific allow-list on every `chezmoi apply`. Manage those per machine via the live file directly, or move to a `--argjson allow $merged` array-union approach if you ever need a shared baseline.

### OpenCode — [`agents/opencode.overlay.json`](../../.chezmoitemplates/agents/opencode.overlay.json)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": true,
  "default_agent": "build",
  "small_model": "github-copilot/gpt-5-mini",
  "agent": { "title": { "reasoningEffort": "low" } },
  "provider": {
    "github-copilot": {
      "options": { "timeout": 600000, "chunkTimeout": 20000 }
    }
  }
}
```

- `$schema` — keeps editors aware of the schema for autocomplete.
- `autoupdate = true` — let the CLI self-update.
- `default_agent = "build"` — primary agent on TUI/CLI startup. Override per-session via `--agent` or the picker.
- `small_model = "github-copilot/gpt-5-mini"` — cheap model for title generation, summarisation, and other lightweight calls. Avoids billing Claude Opus quota for trivial tasks. Pairs with `agent.title.reasoningEffort = "low"`.
- `agent.title.reasoningEffort = "low"` — cheap completions for short title generation; sibling `agent.*` entries (per-agent provider, model overrides) survive.
- `provider.github-copilot.options.timeout = 600000` (10 min) — request-level timeout. Default is 5 min; bumped to give long Claude Opus generations more room before the SDK aborts the whole call.
- `provider.github-copilot.options.chunkTimeout = 20000` (20 s) — abort an in-flight stream if no SSE chunk arrives for 20 s. Counter-intuitive but **this is the fix for the "Tool execution aborted" loop on Copilot's Claude Opus channel**: the Copilot proxy occasionally stalls a stream past its own ~60 s server-side idle window, after which the connection silently dies. With no `chunkTimeout` set, the SDK waits the full request `timeout` for a chunk that will never come; with 20 s the SDK cancels and retries early, getting unstuck in seconds instead of minutes. See [docs/tools/opencode.md](opencode.md#claude-opus-stream-stall-on-github-copilot) for the diagnosis from log evidence.

### Codex — [`agents/codex.config.overlay.toml`](../../.chezmoitemplates/agents/codex.config.overlay.toml)

```toml
personality = "pragmatic"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"

[features]
codex_hooks = true
unified_exec = true
shell_snapshot = true
steer = true
multi_agent = true

[plugins."github@openai-curated"]
enabled = true

[plugins."google-drive@openai-curated"]
enabled = true

[plugins."computer-use@openai-bundled"]
enabled = true
```

- Top-level model + reasoning preferences.
- `[features]` — opt into the experimental flags this user always wants on.
- `[plugins."<id>".enabled]` — curated plugin set; user-installed plugins appear under their own `[plugins."..."]` blocks and are preserved by the deep merge.

## What is intentionally NOT managed

| File / subtree | CLI | Why |
|---|---|---|
| `~/.cursor/{authInfo,auth*,privacyCache,statsigBootstrap,version,hasChangedDefaultModel,...}` | Cursor | Auth + telemetry; runtime-only. |
| `~/.cursor/{extensions,plugins,projects,worktrees,workers,browser-logs,chats,plans,prompt_history.json,argv.json,ide_state.json,agent-cli-state.json,ai-tracking,mcp.json,skills-cursor}` | Cursor | CLI-managed state, per-project, machine-local. |
| `~/.config/opencode/{node_modules,package.json,bun.lock,package-lock.json,plugins/}` | OpenCode | Node runtime + locally-installed plugin source trees. |
| `~/.codex/auth.json` | Codex | OpenAI auth token. **Never** check in. |
| `~/.codex/[projects."<absolute-path>"]` | Codex | Per-project trust grants — absolute paths are machine-specific. **Round-tripped** by the modify_ script (see below). |
| `~/.codex/[marketplaces.<id>]` | Codex | Marketplace registrations with absolute `source = "/Users/.../.codex/.tmp/..."` paths. **Round-tripped**. |
| `~/.codex/{installation_id,history.jsonl,session_index.jsonl,sessions/,logs_*.sqlite*,state_*.sqlite,cache/,tmp/,log/,sqlite/,memories/,vendor_imports/,shell_snapshots/,models_cache.json,plugins/,skills/,rules/,ambient-suggestions/,version.json,AGENTS.md,.tmp/}` | Codex | Sessions, logs, sqlite, plugin/skills directories, machine-local notes. |

The `.chezmoiignore.tmpl` presence-gates the entire `~/.cursor/`, `~/.codex/`, and `~/.config/opencode/` trees with a `stat` check so uninstalled CLIs never produce phantom directories.

## How the Codex TOML merge works

`jq` doesn't speak TOML and `mikefarah/yq`'s TOML emitter produces invalid output for keys with special characters (e.g. `github@openai-curated`). The Codex `modify_` script uses Python instead:

1. Read live file into a `dict` via `tomllib` (Python 3.11+ built-in; `tomli` fallback for 3.10).
2. Pop `[projects]` and `[marketplaces]` subtrees into `state`.
3. Read overlay TOML into a `dict`.
4. Deep-merge: `live_minus_state <- overlay <- state`. Argument order is merge precedence (later wins). State wins last so per-project trust never gets clobbered by an overlay churn.
5. Emit TOML via a 30-line writer that quotes all non-bareword keys (handles `github@openai-curated` and `/Users/me/foo`-style project keys).

The script falls through to passing the live file untouched if `python3` or `tomllib`/`tomli` are missing; chezmoi will skip the file for that apply.

## OpenCode legacy `config.json` migration

OpenCode docs now recommend `opencode.json` as the canonical filename, but installations from before that change use `config.json`. The repo manages only the modern filename; a one-shot script handles the migration:

- [`run_once_before_50_opencode_migrate.sh.tmpl`](../../run_once_before_50_opencode_migrate.sh.tmpl) runs once per source-state hash, before chezmoi deploys files. It:
  1. No-ops if `~/.config/opencode/config.json` is absent.
  2. If only the legacy file exists: rename it to `opencode.json`.
  3. If both exist: deep-merge legacy into modern (modern wins on conflict, since it's presumed newer), then delete legacy.

After this script runs, the `modify_opencode.json` overlay enforces the managed keys on the unified file. The legacy filename never reappears because OpenCode itself only writes `opencode.json` going forward.

The migration script can be removed from the repo a few months after rollout (once all machines have run `chezmoi apply` at least once); it is idempotent and a no-op on fresh machines, so it's safe to leave indefinitely.

## Refresh recipe

To change what an overlay enforces, edit the corresponding `.chezmoitemplates/agents/<cli>.overlay.{json,toml}` file. Do **not** `chezmoi add` the live config — that would strip the `modify_` prefix and overwrite the script with the runtime file (which contains your secrets).

To pull a new key from the live file into the overlay (e.g. you changed a Cursor permission you want shared):

```bash
# 1. Inspect the live file
jq . ~/.cursor/cli-config.json

# 2. Edit the overlay JSON / TOML and add the key
$EDITOR .chezmoitemplates/agents/cursor.cli-config.overlay.json

# 3. Verify the rendered modify_ script outputs what you expect
chezmoi execute-template < dot_cursor/modify_cli-config.json.tmpl > /tmp/m.sh
chmod +x /tmp/m.sh
cat ~/.cursor/cli-config.json | /tmp/m.sh

# 4. Apply
chezmoi apply
```

## Tests

[`tests/unit/agent_overlays.bats`](../../tests/unit/agent_overlays.bats) covers:

- Each overlay enforces its declared keys.
- Live runtime keys outside the overlay are preserved verbatim.
- Codex `[projects.*]` and `[marketplaces.*]` round-trip unchanged (the round-trip property is the load-bearing invariant — break it and machines start clobbering each other's per-project trust).
- The modify_ scripts are idempotent (running output through the script again produces the same output).
- The OpenCode migration handles all three input states: legacy-only, both-present, neither-present.
- The Claude hook-aware merger (see next section): notify.sh added when missing; CodeIsland entries preserved; idempotency on re-apply; non-hook deep-merge preserves user siblings.

Run with `just bats` (or directly: `bats tests/unit/agent_overlays.bats`).

## CodeIsland integration (macOS-only)

[CodeIsland](https://github.com/wxtsky/CodeIsland) is a macOS notch-area HUD (positioning analogous to [CodexBar](https://github.com/steipete/CodexBar)) that surfaces real-time activity from 11+ coding-agent CLIs (Claude Code, Codex, Gemini, Cursor, Copilot, OpenCode, AntiGravity, Trae, Qoder, Factory, CodeBuddy, Kimi). It works by injecting per-CLI hook entries that fire `~/.codeisland/codeisland-bridge` (or `codeisland-hook.sh`), which streams events over a Unix socket at `/tmp/codeisland-<uid>.sock` to the SwiftUI app.

### Why macOS-only

- Swift app, requires macOS 14 (Sonoma) or later.
- The notch UI assumes a MacBook display geometry.
- Distribution is via brew cask (`wxtsky/tap`) or `.dmg`.

There is no Linux fallback — the wire format depends on the macOS-specific bridge binary and socket path. We deliberately install nothing for CodeIsland on Linux and skip all related concerns there.

### Install

The `codeisland` cask is added in [`dot_config/homebrew/Brewfile.darwin.tmpl`](../../dot_config/homebrew/Brewfile.darwin.tmpl) inside the `{{ if .installAiDesktopApps }}` block alongside the other agent desktop apps:

```ruby
tap "wxtsky/tap"
cask "codeisland"
```

### How we coexist with the app

CodeIsland's settings panel calls itself "Auto hook install" with "auto-repair and version tracking" — meaning the **app actively writes and re-writes** hook entries into each detected CLI's config on every launch. Two coexistence patterns:

#### Pattern A — Sidecar files (always-ignored)

CLIs whose hooks live in a dedicated sidecar (containing nothing but CodeIsland hooks) are simply unmanaged by chezmoi. Concretely:

| File | CLI | Why unmanaged |
|------|-----|---------------|
| `~/.codex/hooks.json` | Codex | Pure CodeIsland sidecar (also extended by Superset's notify.sh in some setups, but that's installed by Superset, not us) |
| `~/.cursor/hooks.json` | Cursor | Same |
| `~/.copilot/hooks/codeisland.json` | GitHub Copilot CLI | Pure CodeIsland sidecar |
| `~/.gemini/settings.json` | Gemini CLI | Currently nothing else to enforce there |
| `~/.antigravity/settings.json` | AntiGravity (CLI, not the editor) | Currently nothing else to enforce there |

These paths are added to [`.chezmoiignore.tmpl`](../../.chezmoiignore.tmpl) as **always-ignore** so accidentally running `chezmoi add ~/.codex/hooks.json` won't pull a CodeIsland-owned file into the source tree (which would clobber the app's runtime updates and create a ping-pong with its auto-installer).

If you later want to manage non-hook prefs in `~/.gemini/settings.json` or `~/.antigravity/settings.json`, write a `modify_` overlay that follows the hook-aware pattern below — and remove the corresponding ignore line.

#### Pattern B — Mixed files (hook-aware merger)

Files where stable user prefs and CodeIsland hooks coexist need a smarter overlay. Currently the only such file is **`~/.claude/settings.json`** — Claude Code stores model selection, plugins, statusLine, and `permissions.defaultMode` in the same file as `hooks.<event>` arrays. A naive `jq '. * $overlay'` deep-merge replaces arrays wholesale: declaring a `hooks.Notification` entry in our overlay would silently delete every CodeIsland entry on each `chezmoi apply`, then CodeIsland would re-install on next launch — endless ping-pong producing diff noise and broken integrations.

[`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) solves this with a hook-aware merger:

1. **Non-hook keys** (`enabledPlugins`, `extraKnownMarketplaces`, `skipDangerousModePermissionPrompt`, `statusLine`, …) deep-merge normally via `base * overlay_no_hooks`.
2. **`hooks.<event>` arrays** are merged additively: for each event the overlay declares, append entries whose `.hooks[0].command` isn't already represented in the live array (string-equality match). Live entries are preserved verbatim, no entry is ever removed.

The full filter (jq):

```jq
. as $base
| ($overlay | del(.hooks)) as $non_hook_overlay
| ($overlay.hooks // {}) as $overlay_hooks
| ($base * $non_hook_overlay) as $merged
| $merged
| .hooks = (
    ($merged.hooks // {}) as $live_hooks
    | reduce ($overlay_hooks | to_entries[]) as $ev (
        $live_hooks;
        .[$ev.key] = (
          (.[$ev.key] // []) as $live_arr
          | ($live_arr | map(.hooks[0].command? // "")) as $live_cmds
          | $live_arr + (
              $ev.value
              | map(select(
                  (.hooks[0].command? // "") as $cmd
                  | ($cmd == "") or (($live_cmds | index($cmd)) == null)
                ))
            )
        )
      )
  )
```

Test coverage in `tests/unit/agent_overlays.bats`:

- `claude modify_settings: notify.sh added to empty hooks, codeisland entries preserved` — proves the additive append works without removing CodeIsland entries.
- `claude modify_settings: idempotent when notify.sh already present` — proves no duplicate appears on re-apply.
- `claude modify_settings: empty live file produces overlay-only output` — bootstrap on a fresh machine.
- `claude modify_settings: non-hook deep-merge preserves siblings` — proves user-added plugins/marketplaces survive.

### Future work (deferred)

- **Apprise-to-webhook expansion of `~/.claude/hooks/notify.sh`**: the script already calls `apprise --tag desktop` for local OS notifications. Could be extended to also fire `apprise --tag webhook` for remote chat-app delivery (Slack, Discord, Telegram, …) using URLs configured in `~/.config/apprise/apprise.yaml`. Open question: noise filtering — should webhook fire on every `Notification`/`Stop`, or only on permission-request and session-end? Likely needs an env-var gate (`CLAUDE_NOTIFY_WEBHOOK=1`) so each machine opts in. Track in a separate change.
- **Managed overlays for `~/.gemini/settings.json` and `~/.antigravity/settings.json`**: defer until concrete prefs need enforcing. When added, follow the hook-aware merger pattern from Claude (each of those files also has CodeIsland-injected `hooks` blocks today).
