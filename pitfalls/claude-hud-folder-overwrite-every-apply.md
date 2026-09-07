# chezmoi repeatedly asks to overwrite the claude-hud folder, with no diff option

**Symptoms**: directory overwrite prompt on `.claude/plugins/claude-hud`,
no diff choice, unchanged `config.json`.
**First seen**: 2026-09
**Affects**: claude-hud 0.8.0, chezmoi 2.69.4; reproduced on macOS arm64.
**Status**: fixed by managing the directory with `private_`.

## Symptom

The isolated reproduction printed this prompt verbatim:

```text
.claude/plugins/claude-hud has changed since chezmoi last wrote it (overwrite/all-overwrite/skip/quit)?
```

`config.json` was byte-identical. `chezmoi diff --no-pager` showed only:

```diff
diff --git a/.claude/plugins/claude-hud b/.claude/plugins/claude-hud
old mode 40700
new mode 40755
```

## Root cause

[HUD v0.8.0 `writeVersionCache`](https://github.com/jarrodwatts/claude-hud/blob/v0.8.0/src/version.ts)
stores `.claude-code-version-cache.json` directly inside the HUD directory
and calls `chmodSync(cacheDir, 0o700)`. The plain chezmoi source directory
expected `0755` on this host. Each cache rewrite could undo chezmoi's mode,
causing the next apply to prompt about metadata instead of file contents.

The native cache writer was tested in a temporary `CLAUDE_CONFIG_DIR`: mode
changed from `0755` to `0700`, the config stayed identical, and the next
isolated apply produced the prompt above.

## Fix

Rename the source directory from `dot_claude/plugins/claude-hud/` to
`dot_claude/plugins/private_claude-hud/`. The deployed name stays
`~/.claude/plugins/claude-hud/`; its mode becomes `0700`, matching HUD.
Keep the config as a normal managed file and leave caches unmanaged.

```sh
chezmoi apply --exclude=scripts ~/.claude/plugins/claude-hud
chezmoi status --recursive ~/.claude/plugins/claude-hud
chezmoi diff --no-pager --recursive ~/.claude/plugins/claude-hud
```

Both status and diff should be empty after HUD writes its cache. No global
`--force`, cache deletion, or JSON merger is needed for this conflict.

## Prevention

Keep the `private_` directory attribute even though its child config is a
plain file. `tests/unit/claude_hud.bats` exercises repeated cache/apply cycles
and migration from the old conflicting source, including cache preservation.

## Related

- [HUD configuration and wrapping](../docs/tools/claude-hud.md)
- [CC version missing despite the enabled flag](claude-hud-version-missing-with-show-version-enabled.md)
