# pueue — task queue with AI summaries + cross-host view

Local CLI plus a fleet-wide command for [pueue](https://github.com/Nukesor/pueue),
a parallel task queue. Three layers:

- `pqsum` — local queue summary. Three modes: deterministic table (`text`,
  default), AI summary with cleanability + recovery verdicts (`ai`), and
  machine-readable parsed JSON (`json`).
- `fleet pueue` — same view across every host in `~/.config/fleet/machines.toml`
  via SSH. Read-only this round (no `pueue add` / `clean` over SSH); deferred
  to a future TLS layer.
- `tv pueue` — terminal-picker UI over running/finished tasks (existing
  cable; unchanged by this work).

## Install

Already deployed via chezmoi:

- `pueue` + `pueued` via Homebrew (macOS) or `cargo install pueue --locked`
  + systemd-user service (Linux). See `dot_ansible/roles/devtools/` and
  `dot_ansible/roles/rust_cargo_tools/`.
- `~/.dotfiles/bin/pqsum` — the uv-script binary (this work).
- `~/.dotfiles/bin/fleet` — adds the `pueue` subcommand (this work).

On macOS the daemon is managed by a Homebrew launchd service — start it with
`brew services start pueue` (or run `pueued -d` by hand). Note the formula ships
`keep_alive false` + `RunAtLoad`-only, so if `brew services start` coincides with
an upgrade/relink the daemon may load but never execute (client then reports
`Couldn't find a configuration file` or a missing `pueue_<you>.socket`). Recover
with `launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.pueue` — see
[`pitfalls/pueue-macos-launchd-not-autostarted-no-socket.md`](../../pitfalls/pueue-macos-launchd-not-autostarted-no-socket.md).
On Linux it's managed by a user-level systemd unit.

## `pqsum` — local summary

```bash
pqsum                       # text table (overall + status breakdown + groups)
pqsum --group default       # restrict to one group
pqsum json                  # parsed JSON to stdout (envs stripped)
pqsum ai                    # AI summary with cleanability + recovery hints
pqsum ai --report           # markdown report to stdout
pqsum ai --report --out ~/notes/pueue-2026-05-13.md
pqsum ai --clean            # report, then prompt y/N per safe-to-clean group
pqsum ai --clean --yes      # same, but skip prompts
```

### Cleanability tiers (mirrors `tsum`'s safe/check/keep)

The AI rates each group:

| Tier | Meaning | Suggested action |
|------|---------|------------------|
| 🟢 `safe-to-clean` | All tasks `Done` + `Success`, last task ended >2h ago, nothing queued/paused. | `pueue clean -g <group>` |
| 🟡 `review` | Mixed Done+Failed, recent (<2h), or Stashed/Paused present. | User judgement before cleaning. |
| 🔴 `keep` | Has Running/Queued, or fresh failure (<10min) with no recovery hint, or `--after` chains still pending. | Don't touch. |

The conservative bias is intentional: when in doubt the LLM is instructed to
pick the safer tier (`keep > review > safe-to-clean`). `pqsum ai --clean`
**only** ever acts on `safe-to-clean` — `review`/`keep` are never auto-cleaned
even with `--yes`.

### Recovery hints for Failed tasks

For each Failed/Killed task the AI emits a `recovery_hint` + optional
`recovery_command`. Heuristics in the prompt:

| Signal | Hint |
|--------|------|
| Same command as a successful later task in the same group | "already covered by task N (succeeded with same args)" |
| Exit 124 | timeout → "increase --timeout, then `pueue restart`" |
| Exit 137 | OOM-kill → "increase memory; `pueue restart` with larger limit" |
| Exit 143 | SIGTERM → "transient; `pueue restart`" |
| Same exit code across consecutive tasks | "group/env misconfig, not per-task" |
| Stale Paused >24h | "stale; `pueue start` or `pueue remove`" |

Recovery commands are **never** auto-executed by `--clean` — that flag only
touches `safe-to-clean` cleanup. A future `--restart-failed` flag (tracked
in TODO.md) will do recovery commands with the same y/N safeguards.

### AI cache

Results cache at `$XDG_CACHE_HOME/pqsum/<host>-<prompt_hash>.json` (default
`~/.cache/pqsum/`). Re-runs within `PQSUM_MIN_REFRESH_INTERVAL` seconds
(default 120) reuse the cached LLM output. Force fresh: `pqsum ai --refresh`.

## Agent wakeups

`agent-wakeup` uses pueue as a small persistent scheduler for quota/rate-limit
resets in live coding-agent panes. It creates group `agent-wakeup`, sets group
parallelism to 1, and labels each task as `agent-wakeup:%pane_id`.

```bash
agent-wakeup status
agent-continue-at --pane %12 --at 01:52am
agent-wakeup send-now --pane %44 --auto
agent-wakeup send-now --pane %44 --enter-only
agent-continue-at --current --delay 70m
agent-wakeup cancel --pane %12
```

The scheduled command calls back into
`~/.config/television/agent-wakeup.py send-now`. When the task runs, it
captures the target tmux pane again. If the original quota marker has
disappeared, the task exits without sending text unless `--force` was used.
That guard is intentional: scheduled `continue` should not type into a pane
that may already have resumed or changed context.

Use `--auto` when you do not know whether the pane needs `continue` or only
`Enter`: Claude's `/rate-limit-options` screen is treated as `Enter` because
`Stop and wait for limit to reset` is already selected; normal prompts use
`continue` + Enter. Use `--enter-only` to force the menu selection.

For the dashboard UI, use `tv agent-wakeup` or tmux `prefix + M-a`. See
[Agent pane discovery](agent-panes-discovery.md#tv-agent-wakeup-quota-waits--scheduled-continue).

### Agent selection

Same SSOT as `tsum` / `aifix` / `aiblock`:
`dot_config/shell/04_ai_agents.sh`. Priority order (env var
`AICAP_AGENT_PRIORITY`): `opencode claude codex cursor-agent`. Override
per-call with `AICAP_AGENT=claude pqsum ai`.

## `fleet pueue` — cross-host

```bash
fleet pueue                          # table: host × group rows
fleet pueue --json                   # one record per host with parsed snapshot
fleet pueue --hosts self,ts_nas      # subset
fleet pueue --group default          # filter to one group across hosts
fleet pueue --ai                     # cross-host AI summary
fleet pueue --ai --report --out ~/notes/fleet-pueue.md
```

### How it works

1. SSH-execs a tiny shell sentinel on each host that prints
   `PQSUM_SOURCE=ok\n<raw pueue JSON>` (or `=missing` / `=offline` if pueue
   isn't installed or the daemon is down).
2. For OK hosts, pipes the raw JSON through the **local** `pqsum json
   --raw-stdin --host=NAME` so the parser only lives in one place.
3. Renders one Rich row per (host, group), or `--json` dumps the per-host
   records, or `--ai` merges everything and pipes to `pqsum ai --stdin-json
   --multi-host`.

The plumbing reuses `scripts/fleet/`'s asyncssh + semaphore-8 pattern from
`scripts/fleet/tmux.py` and `scripts/fleet/info.py`; host failures are
isolated per-row, never abort the run.

### Why `--clean` is local-only

Cross-host `pueue clean` would either need (a) SSH-execing destructive ops
across N machines without per-host confirmation, or (b) the upstream TLS
remote-connect layer (see below). The interactive y/N flow doesn't compose
well across 5 hosts × 3 groups = 15 prompts. For now: do it host-by-host
via local `pqsum ai --clean` or `ssh HOST pueue clean ...`.

## Deferred: TLS remote-connect

Pueue supports a [native remote-connect protocol](https://github.com/Nukesor/pueue/wiki/Connect-to-remote)
where the daemon binds `0.0.0.0:port` and clients use TLS cert + shared
secret to call `pueue -c HOST add/kill/status` directly. This unlocks
write-ops across the fleet (`fleet pueue --clean`, `fleet pueue add ...`).
Tracked in TODO.md as `[?/M] Pueue TLS remote-connect profiles`. For now
fleet stays read-only over SSH.

## Cross-file invariants

The schema emitted by `pqsum json` (or `pqsum json --raw-stdin --host=NAME`)
and consumed by `pqsum ai --stdin-json --multi-host` is a contract between
the two scripts. `scripts/fleet/pueue.py` is the only other consumer and
relies on the schema staying stable.

Adding a field to `HostSnapshot`, `GroupRec`, or `TaskRec` in
`dot_dotfiles/bin/executable_pqsum`:

1. Update the dataclass.
2. Update `_host_to_ai_input()` if the field should reach the LLM.
3. Update `PROMPT_PREAMBLE` if the LLM should use the field for verdicts.
4. Verify `fleet pueue --json | jq` sees the new key.
5. Re-read `docs/tools/pueue.md` (this page) for any stale table.

See [CLAUDE.md](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md) "fleet" row for the umbrella contract.

## Troubleshooting

- **`pqsum: pueue not found in PATH`** — install via brew/cargo or run from
  inside an ansible-provisioned shell. Verify with `command -v pueue`.
- **`pqsum: failed to query pueue status`** — daemon down. `pueued -d` to
  start, or check the systemd unit on Linux (`systemctl --user status pueued`).
- **AI mode hangs / returns nothing parseable** — no agent on PATH or the
  LLM returned non-JSON. `pqsum ai --dry-run` prints the prompt without
  calling the LLM; `AICAP_AGENT=http AICAP_HTTP_API_KEY=... pqsum ai` forces
  the HTTP fallback. The cache also self-heals after the next successful run.
- **`fleet pueue` shows `daemon-offline`/`not-installed`** — the host's
  daemon isn't running or pueue isn't installed. Fix on that host; rerun.
- **Secrets in `pueue status --json` output** — pueue captures the env of
  the shell that ran `pueue add` for every task. `pqsum`'s parser strips
  `envs` before any downstream use (AI prompt, JSON output, cache). Never
  pipe the raw `pueue status --json` into anything else — use `pqsum json`.
