# Plan: `fleet pueue` cross-host queue view + `pqsum` AI summarizer (with cleanup/recovery analysis)

## Context

Surfaced 2026-05-13. Pueue is installed everywhere (brew on macOS, cargo+systemd-user on Linux). Today `pqsum` (zsh function, `dot_config/zsh/tools/36_pueue.zsh:33`) prints a per-group queue table — but only for *one* host you're logged into. There is no cross-host view, and the only existing AI summarizer is `tsum` for tmux.

Goal: bring pueue to parity with `tsum` / `fleet tmux` / `fleet info`, **plus** extend the AI summary with actionable cleanup + failure-recovery suggestions (the analog of `tsum`'s `safe/check/keep` closability tiers, applied to pueue groups/tasks).

Three user-confirmed design choices:

1. **Remote model — "Both, layered"**: this round uses SSH fan-out (matches `scripts/fleet/{tmux,info}.py` semaphore-8 asyncssh pattern), works through ProxyJump, zero new infra. A follow-up adds upstream's [TLS remote-connect](https://github.com/Nukesor/pueue/wiki/Connect-to-remote) for `pueue -c HOST add/kill`.
2. **AI scope — "Both fleet + local"**: `fleet pueue --ai` for cross-host *and* `pqsum --ai` for single-host. Forces migrating pqsum from zsh-only function to Python so:
   - Bash gets it (TODO.md:41 zsh→bash port resolved)
   - One AI prompt template shared between local + fleet
   - `fleet pueue --ai` is implemented by piping the merged cross-host JSON *into the same Python binary's AI subcommand*
3. **Cleanup + recovery analysis** (NEW, this turn): the AI mode classifies each task/group and emits cleanup verdicts + failure-recovery suggestions, similar to how `tsum` tells you which tmux sessions are safe to close.

Architecture mirror: `tsum` does the closability-rating thing today (`dot_config/tmux/executable_tmux-session-summary.py:PROMPT_PREAMBLE` lines 450-503 — `closability ∈ safe/check/keep`, `closability_reason ≤50 chars`).

## Approach

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Local single-host:                                                       │
│      pqsum                  → text table (today's behaviour, ported)      │
│      pqsum --ai             → AI summary + cleanup verdicts (NEW)         │
│      pqsum --ai --report    → markdown report + verdicts (NEW)            │
│      pqsum --ai --clean     → markdown report THEN execute cleanups       │
│                                (interactive confirmation per group)       │
│      pqsum --json           → raw merged JSON                             │
│                                                                            │
│  Cross-host:                                                               │
│      fleet pueue            → table (host × group rows)                   │
│      fleet pueue --ai       → cross-host AI summary + verdicts            │
│      fleet pueue --ai --report → cross-host markdown report               │
│      fleet pueue --json     → raw merged JSON                             │
│                                                                            │
│  (--clean is INTENTIONALLY local-only this round. Cross-host destructive  │
│   ops need TLS layer or explicit `ssh HOST pueue clean ...` — out of      │
│   scope; see § Out of scope.)                                              │
└──────────────────────────────────────────────────────────────────────────┘
```

**DRY anchor**: the AI prompt template + agent dispatch + SHA cache + verdict rendering live ONLY in `dot_dotfiles/bin/executable_pqsum`. `scripts/fleet/pueue.py --ai` merges the cross-host JSON, then shells out: `pqsum ai --stdin-json --multi-host` to render. One template, one classifier.

## AI prompt design (cleanup + recovery)

Prompt structure mirrors `tmux-session-summary.py:PROMPT_PREAMBLE` but pueue-themed. Strict-JSON output schema:

```json
{
  "hosts": [                                ← single-element array in local mode
    {
      "host": "chimera",
      "daemon": "Running",
      "groups": [
        {
          "name": "default",
          "summary": "13 done sklearn experiments, all completed cleanly",   ≤80 chars
          "cleanability": "safe-to-clean",   ← safe-to-clean | review | keep
          "cleanability_reason": "all 13 tasks Done, exit 0, no Failed",       ≤60 chars
          "cleanup_command": "pueue clean -g default",                          ← exact command
          "tasks_highlight": [                ← up to 3 noteworthy tasks
            {"id": 47, "status": "Failed", "summary": "OOM on epoch 3",
             "recovery_hint": "task 52 used same args with --mem 8G and succeeded; rerun w/ that flag",
             "recovery_command": "pueue add --after 47 -g default -- python train.py --mem 8G"}
          ]
        }
      ],
      "overall_summary": "1 group safe to clean, 1 task needs recovery (oom)"   ≤120 chars
    }
  ],
  "fleet_summary": "3/5 hosts have nothing pending; chimera has 1 OOM failure with recovery hint"   ← only present in multi-host
}
```

Cleanability tiers:
- **`safe-to-clean`** — group has only `Done` (exit 0) and `Success` statuses; tasks older than 24h; no in-flight or queued. Suggested action: `pueue clean -g <group>` or `pueue remove <ids>`.
- **`review`** — mixed Done + Failed, or recent (<2h) completions, or Stashed/Paused entries. Don't auto-clean; user judgement.
- **`keep`** — has `Running`/`Queued`/`Paused`; or recent failures with no recovery hint; or contains tasks referenced by `--after` chains that are still pending.

Recovery analysis heuristics (in PROMPT_PREAMBLE, given to the LLM):
1. **Same-command-as-a-success**: if a Failed task's command string matches (or fuzzy-matches) a later Done task with same group and same env vars → mark "already covered by task N".
2. **`pueue restart`-eligible**: transient failures (exit 124 timeout, exit 137 OOM-kill, exit 143 SIGTERM) → suggest `pueue restart <id>` with concrete flag adjustments (e.g. for 137 → "increase memory, retry with larger instance").
3. **Cascade failures**: if multiple consecutive tasks failed with same exit code on same group → suggest the group is misconfigured, not the tasks. Recovery hint: "investigate group config (likely OOM / disk / network)".
4. **Stale Paused/Stashed**: tasks Paused for >24h → suggest "stale; either pueue start or pueue remove".

**Cache invalidation**: SHA includes task IDs + status + timestamps, so the cache hits only when the queue state is identical. New task → new SHA → fresh AI call.

**Output formats**:
- `pqsum ai` (default): Rich-rendered blocks per host with color-coded verdicts (green=safe-to-clean, yellow=review, red=keep+failure-with-recovery).
- `pqsum ai --report`: emits a markdown document to stdout (or `--out PATH`). Suggested location: `~/notes/pueue-reports/YYYY-MM-DD-HHMMSS.md` (NOT committed; this is a personal artifact). Sections: "## Summary", "## Cleanup Candidates" (with the exact `pueue clean` / `pueue remove` commands), "## Failures Needing Action" (recovery hints + commands), "## Raw status" (collapsed `pueue status` table).
- `pqsum ai --clean`: emits the report first, then for each `safe-to-clean` group prompts `y/N` and runs the suggested cleanup command on confirm. `--yes` skips prompt (foot-gun guard: requires `safe-to-clean` AND `--yes` together; `review`/`keep` are NEVER auto-cleaned even with `--yes`).

## Files to change

| File | Change | Notes |
|---|---|---|
| `dot_dotfiles/bin/executable_pqsum` | **NEW** Python uv-script (PEP 723). Subcommands: `text` (default), `ai`, `json`. AI flags: `--report`, `--out PATH`, `--clean`, `--yes`, `--multi-host`, `--stdin-json`, `--deep`. Mirrors `pqsum_use_color/_progress_bar/_align_table` helpers from `36_pueue.zsh` (port to Python). | uv-script with `# /// script` PEP 723 header; deps likely just `rich` for table rendering, stdlib for everything else. |
| `dot_config/zsh/tools/36_pueue.zsh` | **DELETE** — file becomes empty after migration. (Three helpers + `pqsum` function all move into Python binary.) | Removes zsh-only `${@[$idx]}` indexing flagged in TODO.md:41. |
| `scripts/fleet/pueue.py` | **NEW** — mirrors `scripts/fleet/tmux.py` skeleton. `discover_pueue(hosts) -> list[HostResult]`, `_run_one(host)` SSH-execs `command -v pueue >/dev/null && pueue status --json 2>/dev/null \|\| echo '{"error":"unavailable"}'`. Parses to `PueueSnapshot` dataclass. Renders Rich table (host × group rows) or JSON. `--ai` flag merges JSON across hosts, pipes to `pqsum ai --stdin-json --multi-host`. `--ai --report` adds `--report` passthrough. | Reuses `_connect_kwargs` (scripts/fleet_apply.py:556) and the `asyncio.Semaphore(8)` + `asyncio.gather` pattern verbatim. |
| `scripts/fleet/__init__.py` | Re-export `discover_pueue`, `PueueSnapshot`. | One-line additions. |
| `dot_dotfiles/bin/executable_fleet` | Add `pueue` subcommand. Flags forwarded: `--hosts`, `--group`, `--json`, `--serial`, `--ai`, `--report`, `--out`, `--deep`. | Follow pattern at existing `tmux`/`info` dispatch sites. **Note**: `--clean` is NOT forwarded — fleet→clean would imply remote destructive ops, deferred to TLS-layer follow-up. |
| `justfile` | Add `fleet-pueue *ARGS:` recipe. | Matches existing `fleet-tmux`, `fleet-info`. |
| `CLAUDE.md` | Two row updates: (a) fleet cross-file row — add `scripts/fleet/pueue.py` and `dot_dotfiles/bin/executable_pqsum`. (b) AI agent autodetect row — pqsum becomes the **third** Python consumer of the SSOT (alongside `tmux-session-summary.py` and `scripts/aiblock.py`). | The duplication-of-3 triggers a follow-up refactor (listed in § Follow-ups). |
| `docs/tools/pueue.md` | **NEW** tool doc covering: install (brief); local `pqsum text/ai/json` including `--report` and `--clean`; cross-host `fleet pueue [--ai] [--json] [--report]`; AI prompt + caching; cleanup verdict tiers + recovery hints semantics; deferred TLS remote-connect (one sentence + link). | Style: match `docs/tools/sms.md`. |
| `docs/tools/pueue.zh-TW.md` | **NEW** zh-TW mirror with terminology rule preamble. | Required by mkdocs i18n. |
| `mkdocs.yml` | Nav entry: `- Pueue: tools/pueue.md`. | After: `uv run mkdocs build --strict`. |
| `docs/this_repo/fleet-apply.md` | Add `pueue` row to subcommand table near `tmux`/`info`. Mention `--ai` and SSH-only/TLS-later layering. | Keep existing invariants intact. |
| `TODO.md` | Mark `[M] Pueue config via chezmoi` as **partial**. Remove `36_pueue.zsh` bash-port entry (resolved). Add: `[?/M] Pueue TLS remote-connect profiles`, `[?/M] Extract AICAP Python dispatch into shared module (3 consumers now)`, `[?/S] Auto-archive pqsum --ai --report output to ~/notes/pueue-reports/`. | Per project-knowledge-harness convention. |

## Architecture detail

### `executable_pqsum` Python structure

```
executable_pqsum
├── PROMPT_PREAMBLE: str   (≈60-line system prompt; strict-JSON spec with cleanability+recovery fields)
├── AGENT_CONFIG: dict     (claude/opencode/codex/cursor-agent; copy from tmux-session-summary.py:95-138)
├── load_ssot()            (regex-parse dot_config/shell/04_ai_agents.sh — fallback when env not inherited)
├── parse_pueue_json(raw)  (port jq pipeline from 36_pueue.zsh:76-238 to Python — overall + per-group + status breakdown)
├── render_text(snapshot)  (port pqsum_progress_bar + pqsum_align_table)
├── render_ai(snapshot, multi_host=False)
│     ├── prompt = PROMPT_PREAMBLE + json.dumps(snapshot)
│     ├── cache_key = sha256(prompt)[:16]
│     ├── ~/.cache/pqsum/<key>.json   (TTL via PQSUM_MIN_REFRESH_INTERVAL, default 120s)
│     ├── on miss → _aiagent_invoke(agent, prompt) → strict-JSON parse → cache + render
│     └── on hit → load cached JSON → render
├── render_report(parsed_ai) → markdown to stdout or --out PATH
├── execute_cleanup(parsed_ai, yes=False) → for each safe-to-clean group: prompt+run command (skips review/keep always)
└── main()
      ├── pqsum [text]                              → render_text(parse_pueue_json(`pueue status --json`))
      ├── pqsum json                                → print parse_pueue_json output
      ├── pqsum ai [--multi-host] [--stdin-json]    → render_ai
      ├── pqsum ai --report [--out PATH]            → render_report
      └── pqsum ai --clean [--yes]                  → render_report + execute_cleanup
```

### `scripts/fleet/pueue.py` structure

```
scripts/fleet/pueue.py
├── @dataclass HostResult: host, daemon_status, groups: list[GroupRec], error: str|None, elapsed_ms
├── @dataclass GroupRec: name, parallel, total, done, pct, eta_s, status_breakdown: dict[str,int],
│                       failed_task_ids: list[int]   ← passed through for AI recovery analysis
├── async def _run_one(host) → HostResult
│     ├── SSH-exec: command -v pueue >/dev/null && pueue status --json 2>/dev/null || echo '{"error":"unavailable"}'
│     ├── on parse/SSH failure: HostResult(error=..., ...) — does NOT abort fleet
│     └── return populated HostResult
├── async def discover_pueue(hosts, parallelism=8, serial=False) → list[HostResult]
│     ├── Semaphore + asyncio.gather (verbatim from tmux.py)
│     └── stderr ticker: "querying N/M hosts..."
├── render_table(results)   → Rich table; one row per (host, group)
├── emit_json(results)      → list-of-dicts JSON to stdout
├── emit_ai(results, report=False, out_path=None)
│     └── subprocess: pqsum ai --stdin-json --multi-host [--report [--out PATH]] (feeds dataclass→JSON via stdin)
└── main(args)              → parse_args + dispatch
```

### Why subprocess shell-out fleet→pqsum (not Python import)

`scripts/fleet/pueue.py` runs from chezmoi source tree (dev) and from `~/.dotfiles/bin/executable_fleet` (deployed). `pqsum` is in `~/.dotfiles/bin/`. Subprocess via PATH works in both contexts and avoids Python-import-path hacks. Tiny overhead compared to AI call. Matches how `fleet info` already shells out to remote tools.

### Why `--clean` is local-only

Three reasons:
1. Cross-host `pueue clean` would need either (a) SSH-exec the destructive op (works but is irreversible across N machines) or (b) TLS remote-connect with `pueue -c HOST clean`. (b) is the proper path and is the planned TLS follow-up.
2. The interactive y/N confirm per group doesn't compose well across hosts (you'd be y/N-ing for 5 hosts × 3 groups = 15 prompts; too much).
3. Bulk-cleanup across the fleet is rare enough that "if you really want it, do it host-by-host" is acceptable friction.

## Out of scope this round

- **TLS remote-connect** — separate follow-up. Tracked as `[?/M] Pueue TLS remote-connect profiles`.
- **`fleet pueue --clean`** — depends on TLS layer above.
- **`pueue add` from fleet** — read-only this round.
- **Daemon autostart on macOS** — covered by existing `[M] Pueue config via chezmoi` TODO.
- **Extracting AICAP dispatch into shared module** — pqsum becomes the 3rd Python consumer (tsum, aiblock, pqsum). 4th consumer triggers extraction.
- **`fleet pueue --watch`** — interactive polling. Add later.
- **`fleet pueue tail HOST:TASK_ID`** — stream remote task log. Users can `ssh HOST 'pueue follow N'`.
- **Auto-archive markdown reports** — `pqsum ai --report` emits to stdout/`--out` only this round; rotating directory under `~/notes/pueue-reports/` is a separate `[?/S]` TODO.
- **`pueue restart` automation** — recovery hints emit the suggested command but never execute it (`--clean` only touches `safe-to-clean` cleanup, never recovery). Auto-restart would need its own confirmation flow.

## Verification

After implementation, before commit:

1. **Local pqsum text mode unchanged**: `pqsum` output matches today's table closely.
2. **Bash compat**: `bash -c 'PATH=~/.dotfiles/bin:$PATH pqsum'` works (previously zsh-only).
3. **Local pqsum JSON**: `pqsum json | jq '.overall.total'` returns expected count.
4. **Local pqsum AI**: `pqsum ai` returns natural-language summary with verdicts. Re-run within 120s → cache hit. With no agent configured → graceful exit-2.
5. **Pqsum AI cleanability verdicts**: prepare a fixture queue (some Done, some Failed, some Running). Verify the LLM tags `safe-to-clean` only when all-Done; `review` for mixed; `keep` when any Running.
6. **Pqsum AI recovery hint**: prepare two tasks where #N (Failed, OOM) and #M (Done, with `--mem 8G`) have similar commands. Verify recovery_hint correctly references #M.
7. **Pqsum AI --report**: `pqsum ai --report --out /tmp/r.md` writes valid markdown with sections (Summary / Cleanup Candidates / Failures Needing Action / Raw status).
8. **Pqsum AI --clean --yes**: only `safe-to-clean` groups get cleaned; `review`/`keep` are skipped even with `--yes`. Confirm via `pueue status` before/after.
9. **Pqsum AI --clean without --yes**: prompts y/N for each safe-to-clean group; `N` skips, `y` executes.
10. **Fleet pueue table**: `fleet pueue` returns rows for all reachable hosts. Hosts where pueued is offline show `—`; not-installed shows explicit status; SSH-unreachable shows error.
11. **Fleet pueue JSON**: `fleet pueue --json | jq 'length'` = host count.
12. **Fleet pueue AI**: `fleet pueue --ai` returns cross-host summary with per-host verdicts AND a `fleet_summary` line.
13. **Fleet pueue AI --report**: writes cross-host markdown report.
14. **`fleet pueue --hosts H1,H2`** narrows subset.
15. **`fleet pueue --group default`** filters per-group.
16. **`just fleet-pueue --json`** justfile recipe works.
17. **mkdocs**: `uv run mkdocs build --strict` — no NEW warnings beyond the pre-existing zh-TW anchor drift in `backlog/mkdocs-anchor-drift.md`.
18. **chezmoi diff** before apply: shows expected adds (executable_pqsum +x, new fleet module) and `36_pueue.zsh` removal.
19. **Cross-shell**: open fresh zsh and bash, both run `pqsum` → identical output.
20. **CLAUDE.md cross-file rows**: re-read after edit to confirm fleet row lists pueue files and AI row lists pqsum as 3rd consumer.

**Edge cases to specifically exercise**:
- Host with pueued **not running** but pueue installed: row shows `daemon offline`, AI cleanability=`keep`/`unknown`.
- Host with pueue **not installed**: explicit `not-installed`, AI skips it.
- One host hangs >60s: semaphore-8 keeps fleet responsive; that host times out per `command_timeout`.
- AI mode when `AICAP_*` env unset + SSOT unreadable (cron context): explicit exit-2, no traceback.
- `pqsum ai --clean --yes` with NO `safe-to-clean` groups: prints "nothing to clean", exit 0.
- `pqsum ai --clean` invoked on a group whose tasks completed <2min ago: LLM should classify as `review`, never `safe-to-clean`.
- Stash/Pause weirdness: 100 Stashed tasks → AI should still classify (likely `review`).

## Critical files

- `/Users/daviddwlee84/.local/share/chezmoi/dot_dotfiles/bin/executable_pqsum` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet/pueue.py` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet/__init__.py` (exports)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_dotfiles/bin/executable_fleet` (dispatch)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet/tmux.py` (REFERENCE skeleton; do not edit)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet_apply.py:556` (`_connect_kwargs` — reuse, do not edit)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/tmux/executable_tmux-session-summary.py:95-138,450-503` (REFERENCE for AGENT_CONFIG + PROMPT_PREAMBLE shape; do not edit)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/shell/04_ai_agents.sh` (SSOT — DO NOT edit)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/shell/04_ai_capture.sh` (`_aiagent_invoke` reference; do not edit)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/zsh/tools/36_pueue.zsh` (DELETE)
- `/Users/daviddwlee84/.local/share/chezmoi/justfile` (add fleet-pueue recipe)
- `/Users/daviddwlee84/.local/share/chezmoi/CLAUDE.md` (fleet row + AI agent row)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/pueue.md` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/pueue.zh-TW.md` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/this_repo/fleet-apply.md` (subcommand table)
- `/Users/daviddwlee84/.local/share/chezmoi/mkdocs.yml` (nav)
- `/Users/daviddwlee84/.local/share/chezmoi/TODO.md` (status updates + 3 new entries)

## Follow-ups (separate tasks)

1. **TLS remote-connect profiles** — `dot_config/pueue/pueue.yml.tmpl` per-host client profiles, daemon bind override (`0.0.0.0:port`), cert distribution, firewall via ansible. Enables `pueue -c HOST add/kill/status` natively → unlocks `fleet pueue --clean`.
2. **macOS pueued autostart** — launchd plist template alongside Linux systemd-user service.
3. **Extract AICAP dispatch into `scripts/aisum/__init__.py`** — `invoke_agent`, `cache_key`, `parse_strict_json`. Migrate `tmux-session-summary.py`, `aiblock.py`, `pqsum` to import from it.
4. **Auto-archive `pqsum ai --report` to `~/notes/pueue-reports/YYYY-MM-DD-HHMMSS.md`** — rotating directory, retention policy.
5. **`pqsum ai --restart-failed`** — execute the recovery commands the AI suggested, with same y/N safeguards as `--clean`.
6. **`fleet pueue --watch` / TUI** — periodic refresh à la `tsum -i` with fzf preview.
7. **`pqsum ai` in tv channel** — Alt+A binding in `dot_config/television/cable/pueue.toml` that runs `pqsum ai` into the preview pane.

## Rationale recap

| Decision | Why |
|---|---|
| SSH fan-out this round | Reuses fleet asyncssh+semaphore; ProxyJump/NAT; zero new infra; matches user's "Both, layered" |
| TLS as follow-up | Native pattern needed for write ops (`pueue clean -c HOST`); cert distribution + port opening non-trivial; not blocking read-only view |
| Migrate pqsum to Python | Required for "Both fleet + local" AI scope to share one template; resolves zsh→bash port TODO; aligns with tsum's Python pattern |
| Delete `36_pueue.zsh` | After migration the file is empty; keeping it just to avoid a delete is noise |
| Subprocess shell-out fleet→pqsum | Works identically in source-tree dev + deployed contexts; AI call dominates latency |
| `--clean` local-only this round | Destructive cross-host ops belong on TLS layer; interactive y/N×N×groups doesn't scale; rare workflow |
| 3-tier cleanability (`safe/review/keep`) | Direct mirror of tsum's `safe/check/keep`; well-validated UX; users already know the mental model |
| Markdown report optional, never default | `pqsum ai` default = interactive Rich blocks; `--report` only when user wants archivable artifact; keeps default fast |
| Auto-archive deferred | Don't write to `~/notes/` without explicit user opt-in; `--out PATH` covers the immediate use case |
| Recovery hints emit commands, never execute | Same safety stance as `--clean` (only `safe-to-clean` is executable); recovery actions are inherently riskier than cleanup → defer auto-execution to a separate `--restart-failed` follow-up |
| Don't extract AICAP module yet | 3 consumers tolerable; extraction has its own risk; defer until 4th |
