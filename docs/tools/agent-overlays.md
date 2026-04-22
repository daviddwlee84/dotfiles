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
  "agent": { "title": { "reasoningEffort": "low" } }
}
```

- `$schema` — keeps editors aware of the schema for autocomplete.
- `autoupdate = true` — let the CLI self-update.
- `agent.title.reasoningEffort = "low"` — cheap completions for short title generation; sibling `agent.*` entries (per-agent provider, model overrides) survive.

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

Run with `just bats` (or directly: `bats tests/unit/agent_overlays.bats`).
