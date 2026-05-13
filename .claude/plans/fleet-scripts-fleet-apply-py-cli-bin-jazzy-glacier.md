# Plan: `fleet` umbrella CLI — extend fleet system with `tmux` / `info` subcommands

## Context

The fleet system (`scripts/fleet_apply.py`) is mature for `chezmoi update --init` orchestration but exposes only `just fleet-*` recipes — which fail outside the chezmoi source dir tree. Two new ops needs:

1. **Cross-host tmux session visibility**: multiple remote machines accumulate stale tmux sessions; the local `tsum` is local-only and AI-driven. Want a quick "what's open where" summary across the fleet.
2. **Cross-host system status**: fastfetch is installed everywhere via the `devtools` ansible role but never queried in aggregate. Want CPU/RAM/disk/uptime/load/docker glance across hosts.

User-locked design choices (asked & answered before this plan):
- **`~/bin/` stays** — bin/ relocation deferred to `backlog/bin-migration.md`
- **Umbrella `fleet` binary** with subcommands (`fleet apply / status / tmux / info / edit / tail / kill / compact`), matches `git`/`gh`/`chezmoi` pattern
- **Remote tmux**: prefer deployed `~/.config/tmux/tmux-session-summary.py --json`, fallback to raw `tmux list-sessions -F …` when missing/broken
- **`fleet info`**: default curated quick view; `--ff` runs fastfetch JSON dump; `--full` runs all built-in modules; `--modules a,b,c` lets user select; per-module fallback → render `"—"` instead of failing the host

## Architecture

```
bin/executable_fleet              ← new umbrella, uv-script
  → discovers chezmoi source-path
  → sys.path.insert + dispatches to scripts.fleet.<sub>.cli

scripts/fleet/                    ← new package
  __init__.py                     (empty marker)
  _lib.py                         (Host, load_hosts, _connect_kwargs,
                                   resolve_passwords, run_fanout,
                                   REMOTE_*/LOCAL_LOG_DIR constants)
  apply.py                        (lifted from current fleet_apply.py)
  tmux.py                         (new)
  info.py                         (new)

scripts/fleet_apply.py            ← becomes 10-line shim
                                   (preserves `./scripts/fleet_apply.py` callers)
```

**Why this shape**: shared inventory loading + asyncssh fan-out + Rich rendering belongs in one place (`_lib.py`); each subcommand keeps its orchestration logic in its own file. Avoids re-importing dataclasses from a `fleet_apply.py` filename that no longer describes the scope.

**Why an umbrella binary (not separate `fleet-tmux`/`fleet-info`)**: tyro supports `subcommand_cli_from_dict` natively; single PATH entry; consistent `fleet --help` discoverability; bin/ stays small.

**Backward compat**: `scripts/fleet_apply.py` keeps its current shebang + PEP-723 header; body becomes `from scripts.fleet.apply import main; sys.exit(main())`. Every `just fleet-*` recipe continues to call `./scripts/fleet_apply.py …` unchanged during the transition. Justfile recipes get rewritten as `fleet <sub>` wrappers AFTER the binary is smoked.

## Files (new / modified)

| File | Change | Rationale |
|---|---|---|
| `bin/executable_fleet` (NEW) | uv-script (`#!/usr/bin/env -S uv run --quiet --script`, PEP-723 deps: `asyncssh>=2.18, tyro>=0.9, rich>=13.9`); locates `chezmoi source-path`, dispatches to `scripts.fleet.*.cli` | Single binary, PATH-discoverable from anywhere |
| `scripts/fleet/__init__.py` (NEW) | Empty package marker | Make `scripts.fleet` importable |
| `scripts/fleet/_lib.py` (NEW) | `Host` (from `fleet_apply.py:62-89`), `load_hosts` (L101-157), `DEFAULT_CONFIG_PATH` (L95), `_connect_kwargs` (L556-577), `resolve_passwords` (L191+), `LOCAL_LOG_DIR`/`REMOTE_*` constants (L243-252), generic `async def run_fanout(hosts, per_host_coro, *, parallelism, serial, console)` carved from `_run()` (L2971-3058) | DRY across apply/tmux/info subcommands |
| `scripts/fleet/apply.py` (NEW) | Current `cli()` body + all `_run_*` helpers + `build_remote_command` + `_classify_drift`; entrypoint `def main()` | Existing logic, just relocated |
| `scripts/fleet/tmux.py` (NEW) | `cli()` for `fleet tmux`, remote dispatcher (preferred `.py --json` + raw fallback), Rich table | See § fleet tmux |
| `scripts/fleet/info.py` (NEW) | `cli()` for `fleet info`, module catalog with linux/darwin dispatch, fastfetch path, per-module fallback | See § fleet info |
| `scripts/fleet_apply.py` (MODIFY) | Body → `from scripts.fleet.apply import main; sys.exit(main())`. Keep shebang + PEP-723 header. | Backward compat for `just fleet-*` recipes |
| `dot_config/tmux/executable_tmux-session-summary.py` (MODIFY) | Insert `--json` flag in `parse_args` (after L818); short-circuit at L829 after `collect_sessions(deep=args.deep)`: `if args.json: print(json.dumps([dataclasses.asdict(s) for s in sessions], default=str)); return 0` | Reuse existing dataclasses, avoid LLM call when fleet just needs raw data |
| `justfile` (MODIFY) | Add `fleet *ARGS: fleet {{ARGS}}` recipe. Leave the 14 existing `fleet-*` recipes as-is for now (they still call `./scripts/fleet_apply.py` which is now a shim). Optionally add `fleet-tmux` / `fleet-info` wrappers for parity. | Muscle memory + new helpers both available |
| `CLAUDE.md` (MODIFY) | Update the cross-file maintenance row at L7-19 from `scripts/fleet_apply.py / justfile fleet-*…` to `bin/executable_fleet / scripts/fleet/ / justfile fleet-*…`. Still points at `docs/this_repo/fleet-apply.md`. | Track new surface |
| `docs/this_repo/fleet-apply.md` (MODIFY) | New sections: `## Umbrella binary` (path discovery, `fleet --help` overview), `## fleet tmux`, `## fleet info`. Document `fleet status` overload (readiness default vs `--live` for process probe). | Single doc anchor for the whole fleet surface |
| `backlog/bin-migration.md` (NEW) | One-shot draft (see § backlog content) | Per project-knowledge-harness convention; captures the deferred decision |

**Note on PEP-723 header for `bin/executable_fleet`**: copy from `bin/executable_sms:1-10` style (`--quiet` flag included), not `scripts/fleet_apply.py:1-9` style — the binary should not log its own startup noise.

## Subcommand mapping

| `fleet <sub>` | Existing `just` recipe | Implementation |
|---|---|---|
| `fleet apply [--hosts ...] [--dry-run] [--force] ...` | `fleet-apply`, `fleet-apply-dry-run`, `fleet-apply-one`, `fleet-diff`, `fleet-apply-file`, `fleet-apply-branch[-force]` | `scripts.fleet.apply.main` |
| `fleet status` (readiness, default) | `fleet-status` | `apply --readiness` path |
| `fleet status --quick` | `fleet-status-quick` | `apply --readiness --readiness-no-fetch` |
| `fleet status --live [--watch N]` | `fleet-apply-status`, `fleet-apply-watch` | `apply --status` path — overload disambiguated via `--live` |
| `fleet tail HOST[:RUN_ID]` | `fleet-apply-tail` | `apply --tail` |
| `fleet kill` | `fleet-apply-kill` | `apply --kill-orphans` |
| `fleet compact [--run-id ID]` | `fleet-apply-compact` | `apply --compact` |
| `fleet edit` | `fleet-edit` | New — port seed text from `justfile:471-476` |
| `fleet tmux ...` | — | new |
| `fleet info ...` | — | new |

**Flag pass-through**: keep tyro signatures from `scripts/fleet/apply.py` verbatim — `fleet apply --hosts X --dry-run --force ...` works identically to today's `./scripts/fleet_apply.py --hosts X --dry-run --force ...`.

## `fleet tmux` design

**CLI**:
```
fleet tmux [--hosts X,Y] [--exclude Z] [--json] [--deep]
          [--connect-timeout N] [--serial] [--max-parallel N]
```

`--with-summary` (LLM aggregate across hosts) → **out of scope this round**; stub raises `NotImplementedError` with a hint to use `tsum` locally.

**Upstream change in `dot_config/tmux/executable_tmux-session-summary.py`** — minimal patch:
1. Add `p.add_argument("--json", action="store_true", help="Emit raw session/window JSON; skip LLM and cache.")` after L818.
2. After L829 (`sessions = collect_sessions(deep=args.deep)`), insert:
   ```python
   if args.json:
       import json as _json
       print(_json.dumps([dataclasses.asdict(s) for s in sessions], default=str))
       return 0
   ```
3. Schema: `Session{name, created, attached, last_attached, windows[], active_pane_tail, active_pane_skipped}` × `Window{index, name, active, cwd, cmd, panes}` — direct `dataclasses.asdict()` of existing dataclasses (L208-227).
4. `--json` interaction: bypasses cache, bypasses LLM, ignores `--dry-run`/`--refresh`/`--no-cache`. `--deep` still controls pane capture.

**Remote dispatcher** (`scripts/fleet/tmux.py`):
```bash
# Single ssh blob per host; tries preferred path then falls back.
set +e
if [ -x "$HOME/.config/tmux/tmux-session-summary.py" ]; then
  out=$("$HOME/.config/tmux/tmux-session-summary.py" --json ${DEEP_FLAG} 2>/dev/null)
  rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"; printf 'TSUM_SOURCE=py\n' >&2; exit 0
  fi
fi
# Fallback: raw tmux capture
printf 'TSUM_SOURCE=raw\n' >&2
tmux list-sessions -F '#{session_name}\t#{session_created}\t#{session_attached}\t#{session_last_attached}' 2>/dev/null
printf -- '---SEP---\n'
tmux list-windows -a -F '#{session_name}\t#{window_index}\t#{window_name}\t#{window_active}\t#{pane_current_path}\t#{pane_current_command}\t#{window_panes}' 2>/dev/null
```

Python parses the raw fallback back into the same `Session`/`Window` JSON schema, so downstream rendering is source-agnostic.

**Rich table columns**:
```
HOST  SOURCE  SESSIONS  WINDOWS  ATTACHED  LAST_ATTACHED  TOP_SESSION
```
- `SOURCE`: `py` / `raw` / `none` (when both paths empty) / `N/A` (host unreachable)
- `ATTACHED`: count of `session.attached == True`
- `LAST_ATTACHED`: max `last_attached` across sessions, humanized (`time.strftime('%Y-%m-%d %H:%M')`)
- `TOP_SESSION`: session with most windows; tie → most recently attached

**`--json`** emits per-host `{host, source, sessions: [...], error: null|str}` to stdout.

## `fleet info` design

**CLI**:
```
fleet info [--hosts X] [--exclude Y] [--ff] [--full] [--modules cpu,mem,disk,...]
          [--json] [--verbose] [--connect-timeout N] [--serial] [--max-parallel N]
```

**Default curated view**: `cpu, mem, disk, load, uptime, docker, chezmoi, os` (8 columns, render in <2s/host).

**Module catalog** (each entry: linux cmd + darwin cmd; runtime picks via `uname -s` in the SSH'd bash blob):

| Module | Linux | Darwin |
|---|---|---|
| `cpu` | `awk -F: '/Model name/{print $2; exit}' /proc/cpuinfo; nproc` | `sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu` |
| `mem` | `awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t-a, t}' /proc/meminfo` | `sysctl -n hw.memsize; vm_stat \| awk '...'` |
| `disk` | `df -PB1 / \| awk 'NR==2{print $3, $2}'` | same (POSIX) |
| `load` | `awk '{print $1, $2, $3}' /proc/loadavg` | `sysctl -n vm.loadavg \| tr -d '{}'` |
| `uptime` | `awk '{print int($1)}' /proc/uptime` | `echo $(( $(date +%s) - $(sysctl -n kern.boottime \| awk -F'[ ,]' '{print $4}') ))` |
| `docker` | `command -v docker >/dev/null && echo "$(docker ps -q \| wc -l) $(docker ps -aq \| wc -l)"` | same |
| `chezmoi` | `chezmoi --no-pager status 2>/dev/null \| wc -l; (cd "$(chezmoi source-path)" && git rev-list --count HEAD..@{u} 2>/dev/null)` | same |
| `gpu` | `nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null` | `system_profiler SPDisplaysDataType -json 2>/dev/null \| jq -r '...'` |
| `network` | `hostname -f; hostname -I \| awk '{print $1}'` | `hostname; ipconfig getifaddr en0 2>/dev/null \|\| ipconfig getifaddr en1` |
| `os` | `(lsb_release -ds 2>/dev/null) \|\| (. /etc/os-release && echo "$PRETTY_NAME")` | `echo "$(sw_vers -productName) $(sw_vers -productVersion)"` |

**Wire format**: one bash blob per host with `set +e`; each module emits `MOD_<name>=<value>` lines (or `MOD_<name>=ERR:<msg>`). Python parses key=value; missing key OR value starting with `ERR:` → render `"—"`; with `--verbose`, log the err to stderr.

**`--ff`**: invokes `fastfetch --format json` over SSH; if `command -v fastfetch` fails → row's `--ff` cell = `"—"`. Output: per-host flat key-value Rich table (or section-per-host with `--json` raw).

**`--full`**: enumerates every module from the catalog (default 8 + `gpu, network`).

**`--modules a,b,c`**: comma-split, intersect with catalog; warn on unknown.

**Failure policy**: per-host orchestration wrapped in `try/except (asyncssh.Error, OSError, TimeoutError)`; host row reads `STATUS=N/A` and `error=<type>`; the run continues. Same pattern as `_run_kill` at `fleet_apply.py:1486-1508`.

**`--json` mode**: per-host `{host, status: "ok"|"N/A", modules: {cpu: {model, cores}, mem: {used_bytes, total_bytes}, ...}, error: null|str}`.

## `backlog/bin-migration.md` (one-shot draft)

```markdown
# bin-migration: relocate ~/bin to a chezmoi-distinct path

**Status**: P? / deferred — `~/bin` works today; collision risk is theoretical, not observed.

**Problem**: `~/bin` is a common collision target — third-party installers (Anaconda, asdf, mise, custom build scripts) may drop binaries there or expect it as user-writable. chezmoi's ownership of `~/bin/sms`, `~/bin/mi-router`, `~/bin/x`, `~/bin/sesh-preview`, `~/bin/fleet` (post-2026-05) makes "where did this binary come from" harder than it could be.

## Options

| Option | Pros | Cons |
|---|---|---|
| Stay at `~/bin/` | Zero migration cost; widely understood | Collision risk persists |
| `~/.dotfiles-bin/` | Prefix telegraphs origin; clean isolation | Non-standard XDG; needs PATH update + every doc change |
| `~/.local/share/chezmoi-bin/` | XDG-aligned ("data" under chezmoi) | `share/` for executables is unconventional; long path |

## Files affected (any migration)

- `bin/executable_sms` / `mi-router` / `x` / `sesh-preview` / `fleet` — rename source dir (`bin/` → e.g. `dot_dotfiles-bin/`)
- `dot_config/shell/00_exports.sh.tmpl:23` — PATH export
- `justfile` — audit for `~/bin` hardcodes
- `docs/this_repo/fleet-apply.md`, any doc mentioning `~/bin/<x>`
- `pitfalls/*.md` — audit before migrating
- `bootstrap.sh` if it mentions PATH

## Migration ordering (when revisited)

1. Add new path to PATH alongside old (so old `~/bin/sms` keeps working during transition)
2. `chezmoi apply` deploys to new path
3. Flip doc references
4. Wait one release cycle
5. Remove `~/bin/` entries

## Decision

Deferred until either (a) a real collision happens, or (b) `bin/` exceeds ~10 entries. Re-evaluate at that point.

## Related

- Original discussion: 2026-05-13 fleet-CLI session (user raised the rename while adding `bin/fleet`)
- Decision rationale: bin-migration risk (5 existing binaries + PATH + docs) is uncorrelated with the value of adding `fleet`; bundling would expand blast radius for no upside.
```

## Cross-file invariant update (`CLAUDE.md`)

Replace the existing row at L7-19 covering `scripts/fleet_apply.py` with:

| Surface you change | Also update | Reference |
|---|---|---|
| `bin/executable_fleet` / `scripts/fleet/` / `justfile` `fleet-*` recipes / `dot_config/fleet/` / sudo helper consumption / `dot_config/tmux/executable_tmux-session-summary.py` `--json` schema | [docs/this_repo/fleet-apply.md](docs/this_repo/fleet-apply.md) | Single doc anchor for the whole fleet surface |

The new invariant: the `--json` schema emitted by `tmux-session-summary.py` and the raw-fallback reconstruction in `scripts/fleet/tmux.py` MUST stay in sync — if you add a field to the `Session`/`Window` dataclass, update both.

## Verification

End-to-end (in order):

1. `fleet apply --hosts self --dry-run` — confirms shim + tyro umbrella works locally
2. `just fleet-apply --hosts self --dry-run` — confirms existing recipe still works (regression)
3. `fleet status` (readiness) + `fleet status --live` — overload disambiguation works
4. `fleet tmux --hosts self` — preferred `.py --json` path; local tmux server populated
5. `fleet tmux --hosts <remote-with-tmux>` — remote `.py --json` path
6. `fleet tmux --hosts <remote-no-py>` — fallback raw path engages (verify `SOURCE=raw` in table)
7. `fleet tmux --hosts <remote-no-tmux-server>` — empty session list, row shows `0` not `N/A`
8. `fleet tmux --hosts <unreachable>` — row `N/A`, run continues (per-host failure isolation)
9. `fleet info` (default 8 modules)
10. `fleet info --ff` — fastfetch JSON dump
11. `fleet info --full --hosts <no-gpu-host>` — `gpu` cell renders `"—"`, others populated
12. `fleet info --modules cpu,mem` — filtered output
13. `fleet info --hosts <no-docker>` — `docker` cell `"—"`, others populated
14. `dot_config/tmux/executable_tmux-session-summary.py --json` locally — schema matches what `fleet tmux` parser expects (no AI agent invoked)
15. Concurrent: `fleet apply --hosts X` + `fleet info --hosts X` — no shared-state collision (info is read-only, doesn't touch `~/.cache/chezmoi-fleet/`)

Edge cases to specifically exercise:
- SSH `connect_timeout` exceeded → `asyncssh.ConnectionLost` → row `N/A`
- Host with `python3` missing (rare; older BSD/CentOS) → preferred `tmux` path fails; fallback works
- Host with mismatched `tmux` binary on PATH (apt 3.2 vs ~/.local/bin/tmux 3.5) → fallback uses whatever `tmux` resolves on remote PATH (same TSUM_TMUX_BIN caveat as today's `tsum`)

## Out of scope (this round)

- **`~/bin/` relocation** — captured in `backlog/bin-migration.md`
- **`fleet tmux --with-summary`** (cross-host AI summary) — stub that raises `NotImplementedError`; revisit if demand
- **fleet write operations beyond chezmoi apply** (e.g. `fleet exec CMD`, `fleet docker compose pull`) — separate task
- **fleet inventory groups/tags** — current flat list still works; revisit when host count > 8
- **Replacing the 14 existing `just fleet-*` recipes with `fleet <sub>` wrappers** — leave them as-is initially (still call `./scripts/fleet_apply.py` which is a shim); convert in a follow-up commit after smoke

## Critical files

- `/Users/daviddwlee84/.local/share/chezmoi/bin/executable_sms` (template for new `bin/executable_fleet` — PEP-723 header style)
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/fleet_apply.py` (source of refactor; L62-89 Host, L101-157 load_hosts, L191+ resolve_passwords, L556-577 _connect_kwargs, L2971-3058 fan-out)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/tmux/executable_tmux-session-summary.py` (L818-829 `--json` insertion point)
- `/Users/daviddwlee84/.local/share/chezmoi/justfile` (L463-554 fleet recipe block)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_config/shell/00_exports.sh.tmpl` (L23 PATH order — no change this round)
- `/Users/daviddwlee84/.local/share/chezmoi/CLAUDE.md` (L7-19 cross-file maintenance table — update row)
- `/Users/daviddwlee84/.local/share/chezmoi/docs/this_repo/fleet-apply.md` (extend with umbrella / tmux / info sections)
