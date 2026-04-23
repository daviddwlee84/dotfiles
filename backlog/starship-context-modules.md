# Starship context-aware modules

**Status**: P1 ready
**Effort**: S
**Related**: `TODO.md` P1 · `dot_config/starship.toml` · related: `dot_config/tmux/theme.tmux2k.conf` (tmux2k right-side `time` segment overlaps with potential starship `[time]`)

## Context

2026-04, while debugging why the starship prompt sometimes shows a long form
(`daviddwlee84 in 🌐 Da-Weis-Mac-mini in chezmoi on  main [$]`) and sometimes a
short form (`chezmoi on  main [$]`) on the same machine. Root cause was SSH
detection (see `Investigation` below). That review surfaced that the current
`starship.toml` only customises symbols/colours and disables `package` — none of
the **context-aware status modules** that activate only when relevant are
enabled, so the prompt is missing a lot of free signal.

## Investigation

Triggering condition for the long-form prompt was `username` + `hostname`
modules' built-in SSH detection:

| Module | Default trigger |
|---|---|
| `username` | root, or `$USER != $LOGNAME`, or any of `$SSH_CONNECTION` / `$SSH_CLIENT` / `$SSH_TTY` set |
| `hostname` | `ssh_only = true` (default), same SSH var checks |

Verified empirically: SSH'd pane shows `SSH_CONNECTION=127.0.0.1 49387 127.0.0.1 22`
(loopback SSH from VS Code Remote-SSH or similar local-to-self tooling); newly
opened pane in same tmux server has `SSH_CONNECTION` cleared because tmux's
`update-environment` default list includes it. `SSH_AUTH_SOCK` survives because
the local client also has it set (overwrite, not delete). Starship's SSH check
deliberately doesn't include `SSH_AUTH_SOCK` (agent ≠ remote session), which is
correct.

This SSH-detection behaviour is desired (it's a useful signal "this command runs
in a remote-style context"), so no change there. The opportunity is the **other**
context-aware modules that are off.

Surveyed starship modules; categorised by trigger type:

**Env var triggered** (same family as `username`/`hostname`):
`singularity`, `container`, `shlvl`, `env_var`, `nix_shell`, `direnv`

**File/directory triggered** (most language modules):
`python`, `nodejs`, `rust`, `golang`, `package`, `docker_context`,
`kubernetes`, `terraform`, `aws`, etc. — already work out of the box for
project dirs.

**State triggered** (only show when "something happened"):
`status` (non-zero exit), `cmd_duration` (long commands), `jobs`,
`battery` (low only), `memory_usage`, `git_state` (mid-rebase/merge/cherry-pick)

**Git** (mixed): `git_status` symbols are conditional — `[$]` already showing in
the prompt = stash exists in the repo (verified: `git stash list` against the
chezmoi repo returns non-empty; not a decoration).

## Options considered

For the four state-triggered modules that are clearly "free signal, no clutter":

| Module | Add? | Reason |
|---|---|---|
| `status` | ✅ | Most useful — failed command → red `[✘ N]`. Currently disabled by default. |
| `cmd_duration` | ✅ | Auto-shows for commands > 2000ms. No clutter for fast commands. |
| `shlvl` | ✅ | Catches "tmux inside tmux" / "nix-shell inside nix-shell" mistakes. Threshold = 2. |
| `container` | ✅ | Shows when inside `docker exec` / devcontainer. Almost zero false positives. |
| `time` | ❌ | `tmux2k` right-side already has a `time` segment; would duplicate. |
| `memory_usage` | ❌ | 75% threshold rarely hit on dev boxes; low signal. |
| `battery` | ⚠️ | No-op on Mac mini (no battery); harmless if added. Skip for now to keep config tight. |
| `kubernetes` | ⚠️ | Disabled by default. Add when actually using `kubectl`; not currently. |
| `git_metrics` | ❌ | `+lines/-lines` in prompt is noisy for everyday work; better as on-demand command. |

## Implementation

Append to `dot_config/starship.toml`:

```toml
# Failed command → red badge (only on non-zero exit)
[status]
disabled = false
symbol = "✘"
success_symbol = ""
format = '[\[$symbol $common_meaning$signal_name$maybe_int\]]($style) '
map_symbol = true
style = "bold red"

# Long-running commands → show duration after completion (>2s)
[cmd_duration]
min_time = 2_000
show_milliseconds = false
format = "[took ⏱ $duration]($style) "
style = "yellow"

# Shell nesting detector (tmux-in-tmux, nix-shell-in-nix-shell, etc.)
[shlvl]
disabled = false
threshold = 2
symbol = "↕ "
format = "[$symbol$shlvl]($style) "
style = "bold yellow"

# Container marker (docker exec, devcontainer, podman)
[container]
format = '[⬢ \[$name\]]($style) '
style = "bold red dimmed"
```

## Open questions

None — all four additions are pure-additive and contextual. Ship in next batch.

## References

- Starship docs: https://starship.rs/config/
- `username` SSH detection source: https://github.com/starship/starship/blob/master/src/modules/username.rs
- tmux `update-environment` default: `man tmux` → search "update-environment"
- Today's debugging session that surfaced this: `.specstory/history/2026-04-23_*.md`
