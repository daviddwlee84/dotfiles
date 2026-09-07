# Claude HUD omits CC version despite showClaudeCodeVersion being enabled

**Symptoms**: no `CC v…` label with `showClaudeCodeVersion: true`, while
`claude --version` succeeds; version cache contains `"version": null`.
**First seen**: 2026-09
**Affects**: claude-hud 0.8.0; reproduced on macOS arm64 with Claude Code 2.1.261.
**Status**: one-time cache recovery; upstream negative-cache behavior remains.

## Symptom

The local flag was already enabled and the cache referenced the current
Claude binary, but stored `"version": null`. There was no HUD error message.
Direct probing succeeded:

```text
2.1.261 (Claude Code)
```

An isolated copy of the cache returned `null` through HUD's own version
reader. Removing that test cache and repeating the call returned `2.1.261`.

## Root cause

[HUD v0.8.0 `getClaudeCodeVersion`](https://github.com/jarrodwatts/claude-hud/blob/v0.8.0/src/version.ts)
runs `claude --version` with a two-second timeout. A failed or unparseable
probe is persisted as `null`. The reader reuses that result while the
resolved binary path and mtime match, without retrying or expiring it.
The initial failure's cause was not established; timeout is only one possibility.

This incident was not caused by an off flag or by first-line overflow.
v0.8.0 wraps between segments when terminal width is known.

## Recovery

First verify `claude --version` succeeds. Then remove **only** a regular
version-cache file whose parsed `version` field is explicitly `null`:

```sh
claude --version
python3 - <<'PY'
import json
import os
from pathlib import Path

config_dir = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
cache = config_dir / 'plugins/claude-hud/.claude-code-version-cache.json'
if cache.is_file() and not cache.is_symlink():
    data = json.loads(cache.read_text())
    if 'version' in data and data['version'] is None:
        cache.unlink()
        print('Removed failed version cache; the next HUD render will retry.')
PY
```

The next HUD invocation should recreate a valid cache and display `CC v…`.
If it remains absent, inspect the command's actual PATH/width and the newly
written cache. Do not clear all HUD caches or hard-code a version label.

## Prevention

No periodic deletion or modification of the plugin cache code is installed.
If the failure recurs, repeat the guarded recovery after diagnosing the
probe, or adopt an upstream release with negative-cache expiry when available.
The visible version is Claude Code's version, not the HUD plugin's version.

## Related

- [HUD configuration and conditional visibility](../docs/tools/claude-hud.md)
- [Directory overwrite prompt](claude-hud-folder-overwrite-every-apply.md)
