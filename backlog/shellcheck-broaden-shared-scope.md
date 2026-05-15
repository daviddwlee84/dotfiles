# Tighten shellcheck on `dot_config/{shell,bash}/` from severity=error → warning

**Status**: P3 ready
**Effort**: S (~30-60 min batch; mostly mechanical disable directives + 3-5 real fixes)
**Related**: [`.pre-commit-config.yaml`](../.pre-commit-config.yaml) shellcheck-shared hook · [`justfile`](../justfile) `lint-shell` recipe · [`docs/this_repo/testing.md` § shellcheck](../docs/this_repo/testing.md#shellcheck--shfmt)

## Context

**2026-05**: broadened pre-commit's shellcheck scope to cover `dot_config/{shell,bash}/` at `--severity=error` (one new hook entry, alias `shellcheck-shared`). Kept severity at `error` (not `warning`) because the broader scope surfaces ~41 preexisting findings — mostly mechanical false positives in completion files, a few legitimate bugs. Blocking commits on all of them on day one would be hostile to anyone touching unrelated code.

This backlog tracks the cleanup so the hook can drop to `--severity=warning` (matching the original `scripts/` scope) once `just lint-shell` is clean.

## Snapshot of current `just lint-shell` output (2026-05-15)

41 warnings + 0 errors after the SC2142 fix in `50_networking.sh:13`. Three buckets:

### Bucket A — mechanical false positives (~30 of 41)

**SC2207** "Prefer mapfile or read -a" in all bash completion files. False positive for `COMPREPLY=( $(compgen ...) )` — compgen output is word-split-safe by design and that's the canonical bash-completion idiom.

Files (one-line `# shellcheck disable=SC2207` directive at top of each fixes the whole file):

- `dot_config/bash/45_fleet_completion.bash` — 12 instances
- `dot_config/bash/46_mlf_completion.bash` — 6 instances
- `dot_config/bash/48_pqsum_completion.bash` — 3 instances
- `dot_config/bash/49_x_completion.bash` — 2 instances (+ SC2034 for `prev` which is part of the bash-completion API)

**SC1090** "ShellCheck can't follow non-constant source". Files source paths computed at runtime; can't be statically analyzed. Add `# shellcheck source=/dev/null` at each call site.

- `dot_config/shell/10_fzf.sh:25,35`
- `dot_config/shell/27_thefuck.sh:20`
- `dot_config/shell/29_marimo.sh:22`

**SC2034** "appears unused" — false positive for arrays consumed by name (OMB plugins). One disable directive per file.

- `dot_config/bash/01_omb_plugins.bash:22,27,35` (`aliases`, `plugins`, `completions` arrays read by `oh-my-bash` framework at sourcing time)

**SC2154** "pipestatus referenced but not assigned" — false positive in `04_ai_capture.sh:513`; the variable is zsh-only and the surrounding code already gates on `$ZSH_VERSION`. Disable directive at that block.

### Bucket B — real subtle bugs (~8 of 41)

**SC2164** "Use `cd ... || exit/return`" — legitimate; if `cd` fails inside a function the next command runs from the wrong directory. Fixes are one-liners.

- `dot_config/shell/35_yazi.sh:15`
- `dot_config/shell/37_worktrunk.sh:50`
- `dot_config/shell/38_lazyvim.sh:168`

**SC2155** "Declare and assign separately" — `local foo=$(cmd)` masks the exit code. Fixes are mechanical: split into `local foo; foo=$(cmd)`.

- `dot_config/shell/94_ssh_agent.sh:103`
- `dot_config/shell/96_ssh_setup.sh:117`

**SC2088** "Tilde does not expand in quotes. Use $HOME." — likely a real bug.

- `dot_config/shell/99_chezmoi_reload.sh:56`

**SC2087** "Quote 'EOF' to make heredoc expansions happen on the server side" — needs intent check; if the local variables ARE supposed to expand client-side, add `# shellcheck disable` with a comment.

- `dot_config/shell/96_ssh_setup.sh:177`

### Bucket C — stylistic (~3 of 41)

**SC2120** — `_ssh_add_probe` defined to accept args but never called with any. Either drop the references or annotate.

- `dot_config/shell/94_ssh_agent.sh:20`

**SC2139** "This expands when defined, not when used" — alias body that expands `$OSTYPE` at definition time. Probably the intent.

- `dot_config/shell/50_networking.sh:63`

## Suggested batch

1. Bucket A (disable directives): ~10 min, zero risk.
2. Bucket B (real fixes): ~20-30 min, test each with the affected feature (worktrunk navigation, SSH agent setup, etc.).
3. Bucket C: judgment call per case.
4. Flip `.pre-commit-config.yaml` shellcheck-shared `--severity=error` → `--severity=warning`.
5. Update [`docs/this_repo/testing.md` § shellcheck](../docs/this_repo/testing.md#shellcheck--shfmt) to remove the "severity=error while cleaning up" wording.
6. Remove this backlog entry.

## Why not just do it now?

Triage:

- The cleanup is mechanical but touches ~15 files — large blast radius for a side quest.
- The new severity=error hook already catches the one class of bug that matters today (SC2142 alias-with-positional-param), which was the original motivator.
- A flag-day cleanup PR makes review easier than scattering "shellcheck noise" lines across feature commits.

Pick this up next time someone is doing a shell-only cleanup pass or as a `/loop`-able task.
