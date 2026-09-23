# Codex: `Code Mode is unavailable because failed to spawn code-mode host`

**Symptoms** (grep this section):

- In a running Codex TUI:
  ```
  ⚠ Code Mode is unavailable because failed to spawn code-mode host /opt/homebrew/bin/codex-code-mode-host: host executable was not found. Code mode will fail closed; enable `features.code_mode_host` and install `codex-code-mode-host`.
  ```
  (variant: the path in the message is `…/Caskroom/codex/<old-ver>/bin/codex-code-mode-host`)
- `/opt/homebrew/bin/codex-code-mode-host` does not exist — **this is expected**, see below.
- `codex features list` already shows `code_mode_host  stable  true`; the
  "enable `features.code_mode_host`" hint is a red herring.

**First seen**: 2026-09-23 (macOS, codex cask 0.155.1 → 0.156.0)
**Affects**: macOS, Homebrew cask Codex, sessions (re)started while `brew upgrade --cask codex` was running
**Status**: no repo change needed — restart the stale sessions. Upstream: [openai/codex#44261](https://github.com/openai/codex/issues/44261)

## Root cause

Since [Homebrew/homebrew-cask#277837](https://github.com/Homebrew/homebrew-cask/pull/277837)
(authored by the Codex team) the cask unpacks the whole release package and links
**only** `bin/codex`. That is by design: Codex resolves `codex-code-mode-host`,
`codex-path/rg`, `codex-resources/` relative to its *own resolved executable*, so
a fresh `codex` finds `Caskroom/codex/<ver>/bin/codex-code-mode-host` with no
extra link.

The failure happens when a Codex process was **exec'd while Homebrew was mid-upgrade**.
During `brew upgrade --cask` the old tree is temporarily renamed
`Caskroom/codex/<old>.upgrading/`; a process started at that moment maps its image
from there, and once the upgrade finishes that directory is gone. The process keeps
running, but every later host spawn resolves against the deleted tree.

Observed: 22 `codex resume <id>` processes all started within one second of the
cask upgrade; 21 of them mapped `/opt/homebrew/Caskroom/codex/0.155.1.upgrading/bin/codex`.

Diagnose:

```sh
for p in $(pgrep -x codex); do
  printf '%s ' "$p"; lsof -p "$p" 2>/dev/null | awk '$4=="txt" && /Caskroom\/codex/ {print $NF; exit}'
done | grep -E '\.upgrading/|/[0-9.]+/bin' | grep -v "$(brew list --cask --versions codex | awk '{print $2}')/"
```

Any PID listed runs from a stale/deleted tree.

## Fix

Quit those Codex sessions and `codex resume <id>` them again. The new process maps
the current `Caskroom/codex/<ver>/` and finds the host.

**Do not** symlink `codex-code-mode-host` into `$(brew --prefix)/bin`, and don't
`brew reinstall`. Neither fixes it: the stale processes don't use that path, and a
version-pinned link only goes stale on the next upgrade. (Tried and reverted 2026-09-23.)

## Prevention

Don't start or resume Codex sessions while `brew upgrade --cask codex` / `just upgrade-brew`
is running. After a Codex upgrade, restart long-lived sessions (TUI, `app-server`).

## Related

- [`codex-dangling-cask-symlink-signal-killed.md`](codex-dangling-cask-symlink-signal-killed.md) — same cask, `brew cleanup` leaves `bin/codex` dangling
- [`codex-cask-quarantine-gatekeeper-rg-prompt.md`](codex-cask-quarantine-gatekeeper-rg-prompt.md)
