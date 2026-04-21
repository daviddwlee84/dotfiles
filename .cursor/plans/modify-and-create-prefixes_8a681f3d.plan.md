---
name: modify-and-create-prefixes
overview: Convert `dot_claude/settings.json` to `modify_settings.json` (jq deep-merge overlay so chezmoi only enforces 5 managed keys, preserving any runtime-added fields), and convert `dot_config/nvim/lazy-lock.json` to `create_lazy-lock.json` (seed-only, never overwritten after first apply). Eliminates the recurring "diff on every apply" pain for these two files.
todos:
  - id: convert_claude_settings
    content: git mv dot_claude/settings.json to dot_claude/modify_settings.json, replace contents with jq deep-merge overlay script, set exec bit
    status: completed
  - id: convert_lazy_lock
    content: git mv dot_config/nvim/lazy-lock.json to dot_config/nvim/create_lazy-lock.json (contents unchanged)
    status: completed
  - id: verify_no_diff
    content: Run chezmoi diff / apply --dry-run to verify both files no longer produce noise; test fresh-seed behavior for lazy-lock
    status: completed
  - id: update_docs
    content: "Add a 'Selective file management: modify_ and create_' section to CLAUDE.md explaining the overlay pattern, which keys are enforced, and the chezmoi re-add workflow for lazy-lock refreshes"
    status: completed
isProject: false
---

# Stop the recurring diff on Claude settings and lazy-lock

## Problem recap

`chezmoi diff` currently shows drift on `~/.claude/settings.json` every time:

- `+ "skipAutoPermissionPrompt": true` and `+ "permissions": { "defaultMode": "auto" }` — runtime fields Claude Code writes itself
- `statusLine` block gets reordered when Claude serializes the JSON

`lazy-lock.json` drifts on every `:Lazy update` and across OSes.

Two different chezmoi prefixes solve the two different shapes of drift:

- `dot_claude/modify_settings.json` — chezmoi pipes the current target into the script's stdin; the script prints the new contents on stdout. We use `jq '. * $overlay'` to deep-merge our 5 managed keys over the live file, preserving anything Claude Code added at runtime.
- `dot_config/nvim/create_lazy-lock.json` — `create_` only writes when the target does not yet exist (new-machine seed). After that, LazyVim can rewrite the file freely with zero chezmoi diff noise.

## Implementation

### 1) `dot_claude/settings.json` -> `dot_claude/modify_settings.json`

`git mv` first, then replace contents with this shell script (chezmoi executes `modify_` files directly, so it must have exec bit and a shebang):

[dot_claude/modify_settings.json](dot_claude/modify_settings.json)

```sh
#!/bin/sh
# chezmoi modify_ script: deep-merge overlay into existing ~/.claude/settings.json
# Keys in overlay are enforced by chezmoi; any other keys Claude Code writes
# at runtime (permissions, skipAutoPermissionPrompt, model, ...) are preserved.
set -eu

overlay=$(cat <<'JSON'
{
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
    ]
  },
  "enabledPlugins": {
    "pyright-lsp@claude-plugins-official": true,
    "claude-hud@claude-hud": true
  },
  "extraKnownMarketplaces": {
    "claude-hud": { "source": { "source": "github", "repo": "jarrodwatts/claude-hud" } }
  },
  "skipDangerousModePermissionPrompt": true,
  "statusLine": {
    "type": "command",
    "command": "bash -c 'plugin_dir=$(ls -d \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null | sort -V | tail -1); runtime=$(command -v bun 2>/dev/null || command -v node 2>/dev/null); [ -z \"$runtime\" ] && exit 0; rt=\"${runtime##*/}\"; if [ \"$rt\" = \"bun\" ]; then exec \"$runtime\" --env-file /dev/null \"${plugin_dir}src/index.ts\"; else exec \"$runtime\" \"${plugin_dir}dist/index.js\"; fi'"
  }
}
JSON
)

base=$(cat)
[ -z "$base" ] && base='{}'

printf '%s' "$base" | jq --argjson overlay "$overlay" '. * $overlay'
```

Key points:

- `jq '. * $overlay'` does recursive object merge; arrays are replaced wholesale (so `hooks.Notification` won't accumulate duplicates across applies).
- Empty stdin (first-time install, target missing) falls back to `{}`, i.e. writes the overlay as-is.
- chezmoi requires `modify_` source files to be executable. Run `chmod +x dot_claude/modify_settings.json` and confirm with `git ls-files -s dot_claude/modify_settings.json` (mode should be `100755`).
- `jq` is already installed on every profile via the `base` ansible role (listed in [CLAUDE.md](CLAUDE.md) alongside ripgrep/fd).

### 2) `dot_config/nvim/lazy-lock.json` -> `dot_config/nvim/create_lazy-lock.json`

Pure rename, contents unchanged:

```bash
git mv dot_config/nvim/lazy-lock.json dot_config/nvim/create_lazy-lock.json
```

Behavior:

- On a fresh machine, `chezmoi apply` seeds `~/.config/nvim/lazy-lock.json` from the repo version (reproducibility baseline).
- Once the file exists locally, `create_` is a no-op — `:Lazy update` / cross-OS edits never produce chezmoi diff.
- Trade-off: to push a refreshed lockfile back to the repo (e.g. after a deliberate plugin bump), run `chezmoi re-add ~/.config/nvim/lazy-lock.json`. This is a conscious, explicit step instead of constant noise.

### 3) Docs

Add a short "Selective file management: `modify_` and `create_`" section to [CLAUDE.md](CLAUDE.md):

- Explain which keys `modify_settings.json` enforces and how to add more (edit the `overlay` heredoc, `jq '. * $overlay'` handles the rest).
- Note for `create_lazy-lock.json`: use `chezmoi re-add` to promote a local update back to the repo.
- Mention the prerequisite: `jq` (installed by the `base` role).

## Verification

```bash
# Claude settings: diff should be clean even though Claude added new fields
chezmoi diff ~/.claude/settings.json        # expected: no output
chezmoi apply --dry-run -v ~/.claude/settings.json
jq '.permissions, .skipAutoPermissionPrompt' ~/.claude/settings.json   # expected: still present

# lazy-lock: target exists -> create_ is a no-op
chezmoi diff ~/.config/nvim/lazy-lock.json  # expected: no output

# Simulate new-machine seed:
cp ~/.config/nvim/lazy-lock.json /tmp/lazy-lock.backup
rm ~/.config/nvim/lazy-lock.json
chezmoi apply ~/.config/nvim/lazy-lock.json
diff ~/.config/nvim/lazy-lock.json /tmp/lazy-lock.backup   # expected: identical
```

## Out of scope / not doing

- Not converting `lazy-lock.json` to `modify_` with a jq union merge — there is no "managed vs runtime" split, only one writer (LazyVim), so ROI is poor.
- Not touching `dot_claude/hooks/` or `dot_claude/plugins/` — those are static files with no drift.
