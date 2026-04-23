# Add `opencode` to specstory provider auto-wrap list

**Status**: P? deferred — waiting upstream
**Effort**: S (one-line change once upstream lands)
**Related**: `dot_config/zsh/tools/22_sesh.zsh` `_sesh_wrap_agent`,
docs/tools/sesh.md → "Agent wrapping"

## Context

`scode` and `svibe` (and the underlying `_sesh_wrap_agent` helper) auto-wrap
known specstory providers in `specstory run X` to get markdown auto-save
logging. The known-provider list as of 2026-04 is:

```
claude / codex / cursor / droid / gemini
```

`opencode` is intentionally NOT in this list because **specstory itself does
not support it yet**. Calling `specstory run opencode` returns an unknown
provider error, so we currently pass `opencode` through raw — losing the
auto-save markdown that the other agents get.

## Investigation

Upstream tracking (read top to bottom for the latest):

- Issue: <https://github.com/specstoryai/getspecstory/issues/146>
  "Add opencode support" — opened by users running opencode locally and
  wanting the same markdown capture as the other CLIs.
- PR: <https://github.com/specstoryai/getspecstory/pull/156>
  WIP implementation. As of 2026-04 not yet merged. Once merged + released
  in a specstory version, `specstory run opencode` should work.

Local check used during this investigation:

```sh
$ specstory run --help
  Available provider IDs: claude (Claude Code), codex (Codex CLI),
  cursor (Cursor CLI), droid (Factory Droid CLI), gemini (Gemini CLI).
```

Note `opencode` is absent from the available provider list.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Wait for upstream PR #156 to merge, then add `opencode` to the case statement | Zero engineering on our end; consistent with how other providers were added | Blocked on external timeline (unknown ETA) |
| B. Maintain a local shim wrapper that fakes specstory output | We control the timing | Reinvents specstory; output format may diverge from upstream's eventual implementation; high churn |
| C. Use a different recorder for opencode (asciinema, script(1), etc.) | Independent of specstory | Different output format from other agents; breaks the single-source-of-truth markdown story |

Going with A. The cost of waiting is "opencode panes lose the auto-save
nicety"; the cost of B/C is ongoing maintenance plus eventual migration to
upstream.

## Current blocker

Waiting on `specstoryai/getspecstory#156` to merge + ship in a release.

## Activation steps (when unblocked)

When PR #156 merges and is released:

1. Bump local specstory: `npm i -g @specstoryai/specstory@latest`
   (or whatever the install command is on this machine).
2. Verify: `specstory run --help` now lists `opencode`.
3. Edit `dot_config/zsh/tools/22_sesh.zsh` → `_sesh_wrap_agent`:

   ```diff
   -        claude|codex|cursor|droid|gemini)
   +        claude|codex|cursor|droid|gemini|opencode)
                print -r -- "specstory run $agent"
                ;;
   ```

4. Update the case-statement comment + the "Agent wrapping (auto)" tables
   in:
   - `_sesh_wrap_agent` docstring
   - `sesh-code` and `sesh-vibe` `--help` output
   - `docs/tools/sesh.md` → `scode` + `svibe` → "Agent wrapping" sections
5. Move this entry from `TODO.md` (P?) to `## Done`.

## Decision

`2026-04 deferred — waiting on getspecstory#156 release`

## References

- <https://github.com/specstoryai/getspecstory/pull/156>
- <https://github.com/specstoryai/getspecstory/issues/146>
- `_sesh_wrap_agent` in `dot_config/zsh/tools/22_sesh.zsh`
