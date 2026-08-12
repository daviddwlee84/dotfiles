# copilot-proxy global apply mode for Claude Code and Codex

**Status**: deferred (2026-08-12)
**Effort**: L
**Related**: `TODO.md` · `backlog/copilot-proxy-supervisor.md` · `dot_config/shell/43_copilot_proxy.sh`

## Context

The shipped launchers are scoped and reversible: `claude-copilot` and
`codex-copilot` affect one process, while `copilot-here` owns a gitignored
Claude project overlay. A user-wide mode would be convenient, but it would make
ordinary `claude` and `codex` depend on a localhost daemon and would mutate
runtime-owned user config.

## Proposed contract

Use an explicit target such as `copilot-global on|off|status
claude|codex|all`. `on` must prove the supervised proxy/shim healthy, snapshot
the exact files/keys it owns with hashes, write validated temporary files then
atomically replace, and record an ownership/schema marker. Claude gets the
complete role profile; Codex gets the provider/model keys while all unrelated
TOML survives.

`off` restores the snapshot exactly. If current values differ from both the
owned value and snapshot, stop with a drift report rather than overwriting user
changes. Interrupted operations must be restartable and idempotent. Tests need
fresh/existing config, repeated cycles, mid-stage crash, malformed input, manual
drift, state migration, and proxy failure. Implement native PowerShell parity on
Windows.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| Keep one-shot/project launchers | Safe; no restore state or daemon coupling | Repeated opt-in |
| Chezmoi-managed permanent provider | Declarative | Fights runtime writes; may point at a dead daemon |
| Stateful global switch | Best UX with exact restore | Requires supervisor, transactions, drift ownership, platform parity |

## Decision / blocker

Deferred until `copilot-proxy` has a real login-start supervisor and stable log
location. Without that prerequisite a global setting can strand both CLIs after
reboot. Preserve one-shot launchers as the supported path meanwhile.
