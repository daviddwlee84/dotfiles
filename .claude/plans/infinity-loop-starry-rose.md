# Plan: `run-for` — portable time-box wrapper for long-running / infinite commands

## Context

Tools like the new `ping-monitor` (and any "loop forever, Ctrl-C for a summary"
script) have no built-in stop timer — you have to babysit them and hit Ctrl-C.
The user wants a reliable way to say "run this for 5 minutes, then stop" that
still lets the script's `trap INT` summary print.

ChatGPT proposed three options. Findings from exploring the repo:

- **GNU `timeout` is already installed everywhere.** The `devtools` ansible role
  installs `coreutils` (`dot_ansible/roles/devtools/tasks/main.yml:56`), so
  `gtimeout` exists on macOS and `timeout` on Linux (confirmed
  `/usr/local/bin/gtimeout` locally). `coreutils` already has its A–Z row in
  `docs/this_repo/tool-managers.md:947` → **no install or tool-managers change.**
- **`ping-monitor` already traps both `INT` and `TERM`**
  (`dot_dotfiles/bin/executable_ping-monitor:105`), so its summary prints on
  either signal. SIGINT is still the safer default for *arbitrary* trap-based
  scripts (the user's broader case), which is why the wrapper defaults to it.
- **No `run_for`/timeout helper exists yet.**
- ChatGPT's hand-rolled option-3 (`run_for` that backgrounds the command and
  juggles a timer PID) is the most fragile: backgrounding detaches the command
  from the TTY and complicates signal/`trap` behaviour. Since GNU `timeout` is
  already present, a thin wrapper around it is strictly more robust and gets
  `--kill-after` grace + duration suffixes (`5m`, `30s`) for free.

**Decision (from the user):** ship the **generic portable wrapper only**, named
**`run-for`**. No `ping-monitor --for` flag, no other repo changes.

## Change

### 1. Add `run-for` to `dot_config/shell/10_aliases.sh`

This file is the documented home for "POSIX-portable aliases and functions for
both shells" (it already holds hyphenated functions sourced by bash + zsh:
`chezmoi-cd`, `gcam-amend`, `brew-mirror`, `claude-plans-here`,
`ghostty-ssh-terminfo`). The helper is plain POSIX (`command -v`, `$#`, `local`
— `local` is already used in this file's `mi-router-update-completion`), so it
belongs in the shared tier per the three-tier rule, **not** a zsh/bash-only dir.

Add a new section (near the other general functions):

```sh
# --- run-for: time-box any long-running / infinite command -----------------
# Run CMD for at most DURATION, then send SIGINT (same as Ctrl-C) so a script's
# `trap INT` summary still prints; escalate to SIGKILL after a grace if the
# command ignores the interrupt. Wraps GNU timeout — gtimeout on macOS, timeout
# on Linux (both shipped by the coreutils install in the devtools ansible role).
#
# Usage:  run-for DURATION CMD [ARGS...]
#   DURATION takes GNU timeout suffixes: 30s, 5m, 2h, 1d, or bare seconds.
#   RUN_FOR_SIGNAL      signal sent on expiry (default INT)
#   RUN_FOR_KILL_AFTER  grace before SIGKILL (default 5s)
# Exit status: 124 = the time-box was hit (command still running); otherwise
#   the command's own exit status passes through.
# Examples:
#   run-for 5m ping-monitor --gateway 10
#   run-for 30s ./some-infinite-loop.sh
run-for() {
	[ "$#" -lt 2 ] && { echo "Usage: run-for DURATION CMD [ARGS...]" >&2; return 2; }
	local to dur
	to="$(command -v gtimeout || command -v timeout)" || {
		echo "run-for: GNU timeout not found (install coreutils)" >&2
		return 127
	}
	dur="$1"; shift
	"$to" --signal="${RUN_FOR_SIGNAL:-INT}" --kill-after="${RUN_FOR_KILL_AFTER:-5s}" "$dur" "$@"
}
```

Design notes:
- `command -v gtimeout || command -v timeout` → macOS picks `gtimeout`, Linux
  picks native `timeout`; identical command on every machine (the repo's
  cross-platform-muscle-memory principle).
- The `timeout` call is the **last** statement, so its exit status becomes the
  function's return (no temp-rc var to leak). `124` cleanly signals "time-box
  hit"; a self-finishing command passes its own status through.
- Env overrides (`RUN_FOR_SIGNAL`, `RUN_FOR_KILL_AFTER`) cover the rare cases;
  power users wanting full control still call `gtimeout`/`timeout` directly.

### 2. Document it — `docs/shells/aliases.md` (required by the cross-file rule)

The CLAUDE.md contract for "Alias / shell function in `dot_config/{shell,zsh,bash}/`"
requires a row in `aliases.md`. Add to the **Shell Utilities** section
(`docs/shells/aliases.md:686`, format `| Command | Type | Source File | Description |`):

```
| `run-for DURATION CMD...` | function | `dot_config/shell/10_aliases.sh` | Time-box any command: run for DURATION (`5m`/`30s`/bare secs) then send SIGINT (trap-summary friendly), SIGKILL after a grace. Wraps GNU `timeout`/`gtimeout` (coreutils). Exit `124` = time-box hit |
```

### Intentionally NOT changed (contract check)

- **`tool-managers.md`** — no new tool; `coreutils` already listed (`:947`).
- **Completion files** — `run-for` is a shell function wrapping *arbitrary*
  commands, not a `dot_dotfiles/bin/executable_*` CLI, so the Section-F
  completion rule does not apply (there's no fixed subcommand grammar to
  complete).
- **`ping-monitor`** — left untouched per the chosen "wrapper only" scope.

### Optional follow-up (not in scope unless requested)

A one-line usage example (`run-for 5m pinggw`) could be added to
`docs/tools/ping-monitor.md` and/or `docs/playbooks/wifi-latency-spikes.md`,
but neither is required by the cross-file contract.

## Verification

1. **Lint:** `shellcheck dot_config/shell/10_aliases.sh` (repo ships shellcheck) — expect no new findings.
2. **Deploy:** `chezmoi diff` then `chezmoi apply` (only `~/.config/shell/10_aliases.sh` should change).
3. **Both shells source + run cleanly:**
   - `zsh -ic 'run-for 3s sleep 30; echo rc=$?'` → returns after ~3s, `rc=124`.
   - `bash -ic 'run-for 3s sleep 30; echo rc=$?'` → same.
4. **Trap-summary path:** `run-for 5s ping-monitor 8.8.8.8` (or `pinggw`) →
   after ~5s the summary block (min/avg/max, p50/p95/p99, spikes, loss) prints,
   confirming SIGINT reached the script's `trap`.
5. **Pass-through + error paths:**
   - `run-for 30s true; echo $?` → `0` (command finished early, own status passes through).
   - `run-for` (no args) → usage message, exit `2`.
   - `PATH=/usr/bin run-for 3s sleep 1` on a coreutils-less PATH → `run-for: GNU timeout not found`, exit `127`.
6. **Override knobs:** `RUN_FOR_KILL_AFTER=1s run-for 3s sleep 30` still returns ~3s after SIGINT.
