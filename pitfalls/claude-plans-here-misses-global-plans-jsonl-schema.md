# `claude-plans-here` writes settings but does not copy existing global plans

**Symptoms** (grep this section): `claude-plans-here` prints only `Wrote .../.claude/settings.json`; project `.claude/plans/` stays empty; expected plan still lives under `~/.claude/plans/*.md`; Claude session JSONL contains `toolUseResult.filePath` or `ExitPlanMode.planFilePath`.
**First seen**: 2026-06
**Affects**: Claude Code 2.1.x session JSONL on zsh-sourced dotfiles helper
**Status**: fixed in `dot_config/shell/10_aliases.sh`

## Symptom

From a project that already had a global Claude plan:

```text
claude-plans-here
Wrote /path/to/project/.claude/settings.json
```

Expected: the helper should then offer to copy matching plans from
`~/.claude/plans/` into `./.claude/plans/`.

Actual: no orphan-plan prompt appeared, and `./.claude/plans/` remained empty,
even though the matching session file under
`~/.claude/projects/<encoded-project>/*.jsonl` contained the plan path.

## Root Cause

The old helper was brittle in two ways:

1. It stored `"$dir"/*.jsonl` patterns in a variable and later passed the
   variable to `grep`. In zsh, glob patterns introduced by parameter expansion
   are not expanded the same way as literal command-line globs, so the grep
   saw no session files.
2. It parsed one-line JSONL with grep and only looked for `Write` / `Edit`
   `tool_use` rows. Newer Claude Code session rows also expose useful
   authoritative fields such as `toolUseResult.filePath` and
   `ExitPlanMode.input.planFilePath`. Those should count as plan ownership
   evidence, while ordinary assistant/user text mentioning a path should not.

## Fix

`claude-plans-here` now:

- enumerates session files with `find` instead of storing unexpanded globs;
- parses JSONL with `jq` when available;
- detects `Write` / `Edit` / `MultiEdit` input paths, `toolUseResult.filePath`,
  and `ExitPlanMode.planFilePath`;
- keeps a narrower grep fallback for cold-start hosts without `jq`;
- has Bats fixture coverage for old write rows, newer result rows, exit-plan
  rows, git-root session discovery, and false-positive chat mentions.

## Verification

```bash
bats tests/unit/claude_plans_here.bats
```

Manual recovery for an already-affected project:

```bash
cd /path/to/project
claude-plans-here -y
```

The original files in `~/.claude/plans/` are kept; the helper copies with
`cp -n`.

## Related

- [`docs/shells/aliases.md`](../docs/shells/aliases.md#claude-code)
- [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md)
- [`pitfalls/claude-code-keybindings-empty-bindings-array.md`](claude-code-keybindings-empty-bindings-array.md)
