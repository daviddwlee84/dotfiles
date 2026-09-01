# `[claude-hud] Error: level.toLowerCase is not a function` in the Claude Code statusline

**Symptoms** (grep this section):

- The Claude Code statusline is replaced by:
  ```
  [claude-hud] Error: level.toLowerCase is not a function. (In 'level.toLowerCase()', 'level.toLowerCase' is undefined)
  ```
- No file, line, or stack trace — the message names nothing you can grep in
  your own repo, because the code lives in a **plugin cache**, not in the
  dotfiles tree:
  `~/.claude/plugins/cache/claude-hud/claude-hud/<version>/src/effort.ts`
- Appears suddenly after a Claude Code upgrade, with no dotfiles change.
- `~/.claude/plugins/installed_plugins.json` may claim a *different* version
  than what actually runs — `statusLine.command` globs
  `plugins/cache/claude-hud/claude-hud/*/ | sort -V | tail -1`, so the highest
  cached version wins regardless of the metadata file.

**First seen**: 2026-09 (Claude Code 2.1.252, claude-hud 0.1.0)
**Affects**: claude-hud < 0.2 with Claude Code ≥ 2.1.115
**Status**: fixed upstream — claude-hud v0.8.0

## Symptom

The statusline renders only the error string. `src/effort.ts` in the cached
0.1.0 checkout:

```ts
export function resolveEffortLevel(stdinEffort?: string | null): EffortInfo | null {
  if (stdinEffort) {
    return formatEffort(stdinEffort);
  }
  ...
}

function formatEffort(level: string): EffortInfo {
  const normalized = level.toLowerCase().trim();   // <-- throws
```

## Root cause

Claude Code **2.1.115+ changed the statusline stdin schema**: the `effort`
field went from absent to an **object**, `{ "level": "max" }`.

claude-hud 0.1.0 typed it as `string | null` (the field was speculative —
`// Future: Claude Code may expose effort level directly in stdin JSON`). An
object is truthy, so the `if (stdinEffort)` guard passes and
`.toLowerCase()` is called on an object → `TypeError`.

Upstream v0.8.0 `src/effort.ts` documents and handles both shapes:

```ts
export interface StdinEffort { level?: string | null; [key: string]: unknown; }
export type StdinEffortInput = string | StdinEffort | null | undefined;
// "Non-matching inputs (numbers, booleans, arrays, objects without a string
//  `level`) return null rather than crashing."
```

The reason the host was stranded on 0.1.0 at all: this repo is **install-only**
(`AGENTS.md` → "Install vs upgrade is split on purpose"). The `coding_agents`
role installs claude-hud once; refreshing it is an explicit
`just upgrade-plugins` step that had not been run.

## Workaround

```sh
# targeted (what `just upgrade-plugins` calls for this one plugin)
python3 dot_ansible/roles/coding_agents/files/claude_hud_sync.py --only-if-installed
# -> status=changed version=0.8.0 ...

# or the full category
just upgrade-plugins
```

Verify without restarting Claude Code — feed the statusline a payload with the
new `effort` shape:

```sh
echo '{"hook_event_name":"Status","session_id":"t","transcript_path":"/dev/null",
"cwd":"'"$PWD"'","model":{"id":"claude-opus-5","display_name":"Opus 5"},
"workspace":{"current_dir":"'"$PWD"'","project_dir":"'"$PWD"'"},
"version":"2.1.252","effort":{"level":"max"}}' \
  | bun "$(ls -d ~/.claude/plugins/cache/claude-hud/claude-hud/*/ | sort -V | tail -1)src/index.ts"
# expect: [Opus 5 ● max] │ …
```

## Prevention

- N/A structurally — an out-of-tree plugin tracking an evolving host schema
  will drift again. Run `just upgrade-plugins` when the statusline misbehaves.
- Do **not** patch the cached checkout: `claude_hud_sync.py` clones a fresh
  versioned directory per release, so local edits are silently orphaned (and
  the `sort -V | tail -1` glob would keep picking the newest dir anyway).

## Related

- `docs/tools/claude-hud.md`
- `dot_ansible/roles/coding_agents/files/claude_hud_sync.py`
- `docs/this_repo/upgrades.md` → `plugins` category
- Upstream: <https://github.com/jarrodwatts/claude-hud>
