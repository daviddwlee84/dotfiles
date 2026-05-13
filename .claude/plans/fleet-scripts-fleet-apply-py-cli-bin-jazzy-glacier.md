# Plan: `fleet exec` — cross-host argv-list command runner with AI summary

## Context

Surfaced 2026-05-13 after `fleet pueue` shipped (commits `7c130c3` feat + `bae1f48` / `03fcf09` fixes). The pueue work delivered cross-host *structured* probing — JSON queue state pipes into `pqsum ai`. The next gap: cross-host *ad-hoc* command execution.

User signal:
> 然後是不是fleet加一個 可以方便我同時在多臺host上執行command並且等待收集結果的subcommand？

Existing fleet subcommands (`tmux`, `info`, `pueue`) are all specialised: each ships a fixed bash blob and parses structured output. None help when the user wants to:
- Run `pueue --version` everywhere (audit version drift — exactly the jingle207 case)
- Run `df -h /` everywhere (disk pressure check)
- Run `systemctl --user status pueued` everywhere (daemon health)
- Run anything else ad-hoc, just once

`fleet exec` is the missing primitive. Fleet already has the asyncssh + semaphore-8 + inventory plumbing — this is a thin wrapper that exposes it directly. Aligns with the Ansible-ad-hoc / parallel-ssh use case but without leaving the existing umbrella.

ChatGPT's analysis (user-provided 2026-05-13) crystallises the API:
- `--` is the standard wrapper-CLI separator (ssh / docker / cargo / pytest precedent) — argv after it is opaque to fleet's own parser, prevents flag collision
- Argv list (default) is the safe choice — no shell quoting/injection, no accidental globbing
- `--shell` and `--login` are orthogonal opt-ins that compose for users who explicitly want shell expansion or rc-loaded env

User decisions confirmed via AskUserQuestion:
1. **Shape**: argv list, not shell string (default).
2. **AI**: in scope this round.
3. **AICAP module timing**: build `fleet exec --ai` now using the existing AICAP code from `executable_pqsum` (4th Python consumer — extraction TODO promotes from `[?/M]` to higher priority after this).

## Approach

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Default (argv list, no shell):                                          │
│      fleet exec -- pueue --version                                       │
│      fleet exec --hosts H1,H2 -- df -h /                                 │
│      fleet exec --serial -- systemctl --user status pueued               │
│                                                                            │
│  Shell mode (opt-in for pipes / globs / redirects):                      │
│      fleet exec --shell -- 'cat *.log | grep ERROR > /tmp/e.txt'         │
│      fleet exec --shell zsh -- 'echo $0 $ZSH_VERSION'                    │
│                                                                            │
│  Login mode (opt-in for rc-loaded env: aliases, conda, mise, pyenv):     │
│      fleet exec --login -- pueue --version                               │
│      fleet exec --login --shell -- 'conda activate myenv && python ...' │
│                                                                            │
│  AI summary (succeeded / differed / failed tiers):                       │
│      fleet exec --ai -- pueue --version                                  │
│      fleet exec --ai --report --out /tmp/fleet-versions.md -- df -h /    │
│                                                                            │
│  Output formats:                                                          │
│      fleet exec --json -- ...        → JSON array, one record per host   │
│      fleet exec --out-dir DIR -- ... → per-host stdout/stderr/json files │
└──────────────────────────────────────────────────────────────────────────┘
```

The four flags (`--shell`, `--login`, `--ai`, `--json`/`--out-dir`) are independent and compose freely. Defaults bias for safety (no shell, no rc) and speed (no AI).

## API design (locked)

### Argv vs `--shell`

| Mode | Wire format | Use when |
|---|---|---|
| **Default (argv list)** | asyncssh `conn.run(["pueue", "--version"])` — execvp-style on remote, no shell | Most ad-hoc commands. Variable interpolation, pipes, globs DO NOT work. |
| **`--shell`** | `conn.run("bash -c '<reassembled cmd>'")` | Pipes (`|`), globs (`*`), redirects (`>`), env-prefix (`FOO=bar cmd`), `&&` chains. |
| **`--shell zsh`** | `conn.run("zsh -c '<...>'")` | When the user wants zsh-specific syntax. Falls back to bash with a warning if zsh isn't installed. |

`--` is required before the command in BOTH modes. tyro/argparse will refuse to parse fleet flags past `--`, which is exactly the desired behaviour.

In argv mode the command is passed as a list `["pueue", "--version"]`. asyncssh's `conn.run(cmdlist)` quotes per-arg via `shlex.quote()` internally when building the remote string — safe by construction. In `--shell` mode we re-join with `shlex.quote()` per arg into a single string, then prepend `bash -c ` (or whichever shell). The single-arg form `--shell -- 'cat *.log | wc'` is also accepted as a convenience: tyro receives one positional arg, we pass it through verbatim.

### Login vs default

| Mode | Wire format | Use when |
|---|---|---|
| **Default (no-login)** | Direct command + our standard PATH prelude (chezmoi → cargo → uv → ~/bin → brew → linuxbrew) | Most use cases. Fast (no rc-file load), predictable PATH. |
| **`--login`** | Wraps in `bash -lc '<full cmd>'` (with `zsh -lc` if `--shell zsh`) | Tools that need rc-set env: `nvm`, `mise`, `pyenv`, `conda activate`, shell aliases/functions. Slower (~150-500ms per host). |

Caveat noted in docs: on hosts where the user's primary shell is zsh, `bash -lc` doesn't source zshrc — only bashrc/profile. So login mode + zsh-only PATH additions (e.g. conda init blocks in zshrc) won't work unless `--shell zsh --login` is used together.

`--no-augment-path` exists as an escape hatch: skip the PATH prelude entirely (and skip rc-loading) to debug "what does SSH see by default on this host". Mutually exclusive with `--login`.

### `--ai` mode

Mirrors the `fleet pueue --ai` shape but with a different prompt domain. Prompt template:

```
You are reviewing the per-host output of a single shell command run across a
developer's fleet. Identify the cluster-majority output, then classify each
host:

  - "succeeded"  → rc=0 AND stdout matches the majority pattern
  - "differed"   → rc=0 BUT stdout differs (version drift, config drift,
                   different OS, etc.)
  - "failed"     → rc≠0 OR SSH/timeout error

For each host emit a <=60-char `summary` (e.g. "pueue 4.0.1 — older than
cluster majority"; "permission denied on /var/log"; "host unreachable").

Provide a `fleet_summary` (<=160 chars) that highlights the most actionable
divergence — version laggards, failing hosts, anomalous configs.

Respond with STRICT JSON only:
{
  "command": "<argv joined for display>",
  "majority_output": "<the cluster-majority stdout summary, may be empty>",
  "hosts": [
    {"host": "<name>", "tier": "succeeded|differed|failed",
     "summary": "<<=60 chars>", "rc": <int>, "elapsed_ms": <int>}
  ],
  "fleet_summary": "<<=160 chars>"
}
```

AICAP infrastructure is **copy-pasted** from `dot_dotfiles/bin/executable_pqsum`:
- `_SSOT_PATH_CANDIDATES` + `_load_ssot_defaults()` regex parser
- `AGENT_CONFIG` dict + `_with_model()` helper
- `detect_agent()`, `model_for()`, `invoke_agent()`, `_invoke_http()`
- `_CACHE_VERSION`, `_cache_path()`, `_cache_lookup()`, `_cache_save()`
- `parse_reply()` (adapted to the new JSON shape)

This duplicates ~250 LOC, making `fleet exec` the **4th** Python consumer of `dot_config/shell/04_ai_agents.sh` (alongside `tmux-session-summary.py`, `aiblock.py`, `executable_pqsum`). The TODO entry `[?/M] Extract AICAP Python dispatch into shared module` is promoted to higher priority by this commit; doing the extraction first was considered and rejected per user choice ("can have --ai mode with existing AICAP").

`--ai --report` emits markdown (Summary / Succeeded hosts / Differed hosts / Failed hosts / Raw outputs).
`--ai --refresh` bypasses cache.
`--ai --dry-run` prints the prompt without calling the LLM.

### Output table (default render)

```
                          fleet exec — pueue --version
┏━━━━━━━━━━━━━━┳━━━━┳━━━━━━━━━━━━━━━━┳━━━━━━┓
┃ HOST         ┃ RC ┃ STDOUT (1L)    ┃   ms ┃
┡━━━━━━━━━━━━━━╇━━━━╇━━━━━━━━━━━━━━━━╇━━━━━━┩
│ self         │  0 │ pueue 4.0.1    │  120 │
│ hanru_mac    │  0 │ pueue 4.0.2    │  610 │
│ ts_nas       │  0 │ pueue 4.0.1    │  990 │
│ jingle207    │  0 │ pueue 4.0.2    │  450 │
│ david_ubuntu │  0 │ pueue 4.0.2    │  720 │
└──────────────┴────┴────────────────┴──────┘
```

- STDOUT cell: first line of stdout, Rich auto-truncates to terminal width.
- Non-zero RC: red cell + show first line of stderr instead of stdout.
- SSH/timeout failure: RC="N/A", STDOUT="<error class>", row dimmed.
- `--full-output` flag: render the full (host, rc, stdout, stderr) blocks below the table.

`--json` emits one record per host:
```json
[{"host":"self","rc":0,"stdout":"pueue 4.0.1\n","stderr":"","elapsed_ms":120}, ...]
```

`--out-dir DIR` writes per-host files (one set per host):
- `DIR/<host>.stdout`
- `DIR/<host>.stderr`
- `DIR/<host>.json` (rc, elapsed, argv echo)

## Files to change

| File | Change | Notes |
|---|---|---|
| `scripts/fleet/exec.py` | **NEW** ~400 LOC. Mirrors `scripts/fleet/pueue.py` skeleton: `_run_one` over asyncssh with semaphore-8, per-host `HostResult` dataclass, table/JSON/out-dir rendering, `--ai` path that copy-pastes AICAP from `executable_pqsum`. | Owns its own `AGENT_CONFIG`, `detect_agent`, `invoke_agent`, cache. New `AIEXEC_PROMPT_PREAMBLE` constant for the succeeded/differed/failed classifier. |
| `dot_dotfiles/bin/executable_fleet` | Add `exec` to USAGE block + dispatch dict, mirror the `pueue` entry. | The `--` separator must be passed through to `scripts.fleet.exec.main()` — verify tyro accepts unknown args after `--` (already used by tmux/info dispatch). |
| `docs/this_repo/fleet-apply.md` | Add `fleet exec [...]` row to the subcommand table near `tmux` / `info` / `pueue`. | One-line summary + link to `docs/tools/fleet-exec.md`. |
| `docs/tools/fleet-exec.md` | **NEW**. Mirror `docs/tools/pueue.md` structure: install (auto), three modes (argv / `--shell` / `--login`), AI tiers, examples (version audit, disk audit, daemon health). | Includes the orthogonal-flags composition table. |
| `docs/tools/fleet-exec.zh-TW.md` | **NEW** zh-TW mirror with terminology preamble. | Required by mkdocs i18n. |
| `mkdocs.yml` | Nav entry `- fleet exec: tools/fleet-exec.md` under tools section. | Run `uv run mkdocs build --strict` (baseline = 12 pre-existing warnings, none new). |
| `CLAUDE.md` | (a) Fleet cross-file row: add `scripts/fleet/exec.py` and `docs/tools/fleet-exec.md`. (b) AI agent autodetect row: bump consumer count `three → four`; explicitly call out that the extraction TODO is now blocking ergonomics. | Two row edits. |
| `TODO.md` | Promote `[?/M] Extract AICAP Python dispatch into shared module` to `[P2/M]`. Update the `fleet exec` entry status from `Planned` to `Done <date>` with the commit hash. | |
| `backlog/fleet-exec.md` | Status: Planned → Done `<date>`. Add Resolution section noting the API decisions locked here. | Per project-knowledge-harness convention. |

## Architecture detail

### `scripts/fleet/exec.py` structure

```
scripts/fleet/exec.py
├── _SSOT_PATH_CANDIDATES / _load_ssot_defaults / _env_or_ssot
│       (copy from executable_pqsum:30-70)
├── AICAP_* module-level constants
│       (copy from executable_pqsum:73-95)
├── AGENT_CONFIG dict + _with_model
│       (copy from executable_pqsum:97-120)
├── AIEXEC_PROMPT_PREAMBLE: str
│       (NEW — succeeded/differed/failed classifier prompt; ~30 lines)
├── @dataclass HostResult: host, rc, stdout, stderr, elapsed_ms, error
├── async def _run_one(host, argv, shell, login, augment_path)
│       SSH-exec command per the chosen mode; return HostResult
├── async def discover_exec(hosts, argv, shell, login, ...) → list[HostResult]
│       Semaphore + asyncio.gather (verbatim from pueue.py)
├── render_table(results, full_output=False)
│       Rich table; HOST | RC | STDOUT(1L) | ms; --full-output expands blocks
├── emit_json(results)
│       JSON array of records to stdout
├── write_out_dir(results, dir_path)
│       Per-host .stdout / .stderr / .json files
├── invoke_ai(results, argv) → dict | None
│       Build prompt → cache lookup → invoke_agent → parse_reply
│       (copy of executable_pqsum AI path, adapted to new schema)
├── render_ai(parsed, results)
│       Rich blocks: fleet_summary line, then per-tier hosts (succeeded / differed / failed)
├── render_ai_report(parsed, results)
│       Markdown report; sections: Summary / Succeeded / Differed / Failed / Raw outputs
├── cli(...) → int
│       tyro CLI; --hosts/--exclude/--serial/--max-parallel/--shell/--login/
│       --no-augment-path/--json/--out-dir/--full-output/--ai/--report/--out/
│       --refresh/--no-cache/--dry-run + positional `argv: list[str]`
└── main() → int
```

### Critical implementation details

1. **Argv parsing with `--`**: tyro/argparse natively respects `--`. The CLI signature includes a positional `argv: list[str]`. Test that `fleet exec --hosts H1 -- pueue --version` correctly splits fleet flags from the inner command.

2. **PATH augmentation prelude**: when in `--login` mode, wrap as `bash -lc <quoted-cmd>` so login shell expands PATH from rc files. When NOT `--login`, prepend the chezmoi → cargo → uv → ~/bin → brew → linuxbrew prelude (same string as `scripts/fleet/pueue.py:_REMOTE_CMD`) before running the argv. When `--no-augment-path` is set, skip the prelude entirely.

3. **Argv quoting**: `shlex.quote(arg) for arg in argv` to build a safe shell string for both `bash -c` mode and the PATH-prefixed direct mode. Note: asyncssh's `conn.run(str)` always runs the string via `/bin/sh -c`, so even argv mode goes through `sh` — but the per-arg `shlex.quote` makes that safe.

4. **Cache key for `--ai`**: SHA of (PROMPT_PREAMBLE + json.dumps(results)). New host added / different stdout → new SHA → fresh call. Identical results → reuse cache. TTL: `FLEETEXEC_MIN_REFRESH_INTERVAL` env, default 120s.

5. **Output truncation in AI input**: cap per-host stdout/stderr at 4000 chars in the prompt (avoid token blowout). If truncated, indicate `[... N more chars ...]`. This is a hard ceiling — users wanting full output should use `--out-dir`.

6. **Exit code**: `min(N_failed, 125)` where failed = hosts with rc≠0 or SSH error. Matches `fleet tmux` / `fleet info` / `fleet pueue` convention.

7. **Tyro positional argv hand-off**: the `executable_fleet` dispatcher does `sys.argv = ["fleet exec", *rest]` before calling `scripts.fleet.exec.main()`. The `--` and argv after it survive this rewrite naturally.

## Out of scope this round

- **stdin passthrough** — `fleet exec --stdin file.txt -- some-cmd` feeding file.txt to each remote command's stdin. Plausible follow-up.
- **PTY allocation (`-t`)** — interactive commands (vim, less). Doesn't fit fan-out shape.
- **Streaming output** — completed stdout/stderr only this round. Watch / tail is a different shape (separate command).
- **`--ai --restart-failed` / actionable execution** — AI gives summary only; no auto-rerun of failed hosts. Same conservative stance as `pqsum ai --restart-failed` (deferred).
- **Persistent rate-limiting** — semaphore-8 fan-out per invocation; no cross-invocation rate limit.
- **Bitwarden / sudo password injection** — `fleet exec` is for non-privileged ad-hoc commands. For `sudo` use `fleet apply`'s existing password injection path.
- **AICAP shared-module extraction** — declared next priority; not done in this commit.

## Verification

End-to-end checks before commit:

1. **Argv default**: `fleet exec -- pueue --version` returns one row per host, RC=0 for every host that has pueue, RC=N/A for SSH-unreachable.
2. **Argv with flag-collision check**: `fleet exec -- python -c "print('hi')"` — confirm `-c` isn't consumed by fleet's parser.
3. **`--hosts` subset**: `fleet exec --hosts self -- echo hello` runs only on self.
4. **`--shell`**: `fleet exec --shell -- 'echo $HOSTNAME; date'` evaluates the `$HOSTNAME` and runs `date` (proves shell expansion works).
5. **`--shell zsh`**: `fleet exec --shell zsh -- 'echo $ZSH_VERSION'` returns zsh version on hosts with zsh, falls back / errors gracefully on hosts without.
6. **`--login`**: `fleet exec --login -- 'echo $PATH'` returns a rich PATH including rc-set additions (cargo, mise, conda) on hosts where those are set in `~/.bashrc`. (Caveat: zsh-only PATH additions won't show unless `--login --shell zsh`.)
7. **`--no-augment-path`**: `fleet exec --no-augment-path -- echo "$PATH"` returns the minimal SSH PATH (`/usr/bin:/bin:/usr/sbin:/sbin` on macOS; `+ /snap/bin` on Ubuntu). Proves the escape hatch works.
8. **`--json`**: `fleet exec --json -- date | jq 'length'` equals host count.
9. **`--out-dir`**: `fleet exec --out-dir /tmp/exec-test -- ls /tmp` writes one set of files per host with correct rc + elapsed.
10. **`--full-output`**: long stdout renders as block below the table, not truncated.
11. **Non-zero RC**: `fleet exec -- false` returns RC=1 for every host; row is red.
12. **Mix RC**: `fleet exec -- test -f /etc/lsb-release` returns RC=0 on Ubuntu, RC=1 on macOS — table shows the split.
13. **SSH failure**: `fleet exec --hosts <a-down-host> -- echo` shows RC=N/A + error; doesn't abort.
14. **`--ai`**: `fleet exec --ai -- pueue --version` returns succeeded/differed tiers correctly classifying the live version drift across hosts (4.0.1 vs 4.0.2 — matches the known jingle207 case).
15. **`--ai --report`**: `fleet exec --ai --report --out /tmp/r.md -- df -h /` writes valid markdown.
16. **AI cache**: re-running the same `fleet exec --ai -- ...` within 120s hits the cache (visible via stderr log). `--refresh` forces fresh.
17. **AI dry-run**: `fleet exec --ai --dry-run -- pueue --version` prints the constructed prompt; no LLM call.
18. **`--ai` with no agent on PATH**: graceful exit-2 with helpful message.
19. **mkdocs**: `uv run mkdocs build --strict` — 12 pre-existing warnings only.
20. **chezmoi diff** before apply: shows new `scripts/fleet/exec.py`, updated `executable_fleet`, new docs, updated CLAUDE.md / TODO.md / mkdocs.yml.
21. **`fleet --help`**: lists `exec` in the subcommand table.

**Edge cases**:
- Inner command needs `--`-like flag: `fleet exec -- ssh remote -- ls` — the second `--` is part of inner argv, fleet's parser stops at the first.
- Empty argv: `fleet exec --` errors with "missing command after --".
- Single-host subset that's the orchestrator itself: `fleet exec --hosts self -- ...` uses `asyncio.create_subprocess_exec` (no SSH). Same code path as pueue's `host.local` branch.
- `--shell --login` together: `bash -lc <cmd>`. `--shell zsh --login`: `zsh -lc <cmd>`.
- `--no-augment-path --login`: mutually exclusive — error at CLI level. (Login mode loads rc files which set PATH; augmentation would be redundant or conflicting.)
- Inner command produces 50MB of stdout: captured in memory (asyncssh caps at default buffer; we may want `--max-output BYTES` later, but v1 accepts the memory usage).

## Critical files

- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet/exec.py` (NEW — ~400 LOC)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet/pueue.py` (REFERENCE for `_REMOTE_CMD` PATH prelude, asyncssh + semaphore pattern, output rendering; do not edit)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_dotfiles/bin/executable_pqsum` (REFERENCE — copy AICAP code from lines ~30-700: SSOT loader, AGENT_CONFIG, detect_agent, invoke_agent, cache helpers, parse_reply. Do not edit)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_dotfiles/bin/executable_fleet` (add `exec` to USAGE + dispatch dict)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet_apply.py:556` (`_connect_kwargs` — reuse via `from scripts.fleet import _connect_kwargs`)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet/__init__.py` (no new exports needed)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/shell/04_ai_agents.sh` (SSOT — DO NOT edit; exec.py reads it)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/fleet-exec.md` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/fleet-exec.zh-TW.md` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/this_repo/fleet-apply.md` (subcommand table)
- `/Users/daviddwlee84/.local/share/chezmoi/CLAUDE.md` (fleet + AI agent rows)
- `/Users/daviddwlee84/.local/share/chezmoi/mkdocs.yml` (nav)
- `/Users/daviddwlee84/.local/share/chezmoi/TODO.md` (promote AICAP extraction; mark fleet exec done)
- `/Users/daviddwlee84/.local/share/chezmoi/backlog/fleet-exec.md` (status → Done)

## Follow-ups (separate tasks)

1. **AICAP shared-module extraction** — `scripts/aisum/__init__.py` exporting `AGENT_CONFIG`, `detect_agent`, `invoke_agent`, `cache_lookup`, `cache_save`, `load_ssot`, `parse_strict_json`. Migrate the **four** consumers to import. Triggered to higher priority by this commit (was `[?/M]`, becomes `[P2/M]`).
2. **`fleet exec --stdin FILE`** — pipe a local file to each remote command's stdin. Plausible follow-up.
3. **`fleet exec --max-output BYTES`** — cap per-host captured output to bound memory for pathological commands.
4. **`fleet exec --watch N`** — periodic re-run (like `watch -n N` but cross-host). Conflicts with `--ai` cache semantics; needs design.
5. **TV channel `tv fleet`** — interactive picker that shows recent `fleet exec` runs from a history file.

## Rationale recap

| Decision | Why |
|---|---|
| argv after `--` (default) | Standard wrapper-CLI pattern (ssh / docker / cargo / pytest); no shell-quoting footguns; safe by construction. User explicitly chose this. |
| `--shell` opt-in | Lets users access pipes/globs/redirects when needed without burdening the safe default. |
| `--login` opt-in | Some commands need rc-loaded env (conda, mise, pyenv, aliases). Slow (~150-500ms) so not the default. Composes with `--shell`. |
| PATH augmentation by default | Same lesson as `fleet pueue`: brew / cargo / uv tools live in non-default-PATH dirs. Without this `fleet exec -- pueue --version` would falsely show "not installed" on hosts where pueue is at `/opt/homebrew/bin` or `~/.cargo/bin`. |
| `--no-augment-path` escape hatch | For users debugging "what does SSH see by default" — keep the tool inspectable. |
| `--ai` with copy-pasted AICAP (this commit) | User-confirmed: ship feature now, accept 4-consumer duplication, prioritise extraction next. Faster user value. |
| Markdown report mode | Mirrors `pqsum ai --report` UX; archive-worthy artifact for audit use cases (version drift report, disk audit, etc.). |
| Output truncation in table | First line + Rich auto-truncate keeps the table scannable; `--full-output` for verbose blocks; `--out-dir` for raw files. |
| Exit code = N_failed | Matches the convention of other fleet subcommands; lets CI / scripts react to fleet-wide failures. |
| Don't extract AICAP in this commit | Adding the 4th consumer is the forcing function; extracting in the SAME commit blurs review focus and risks regressions in the three existing consumers. Separate commit after this. |
