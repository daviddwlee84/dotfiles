# `fleet exec` — cross-host argv-list command runner with AI summary

**Status**: Done 2026-05-13 — shipped as `scripts/fleet/exec.py`.
**Effort**: M (~600 LOC including copy-pasted AICAP block; ~250 of that is AI infrastructure that will collapse into shared `scripts/aisum/` on next refactor).

## Resolution (2026-05-13)

Shipped exactly as planned with one refinement: the AI prompt cache excludes
`elapsed_ms` from its hash key. The initial implementation included
`elapsed_ms` per host, which varies every run — every invocation produced a
cache miss. Excluding it from the hash payload (the LLM doesn't need
millisecond precision to classify) means identical command outputs reuse the
cached classification regardless of SSH timing variance. Verified locally:
first run 14.8s, second run 1.6s (~9× speedup on cache hit).

All other API decisions held:
- Argv after `--` as default; `--shell bash|zsh|sh` opt-in for pipes/globs.
- `--login` opt-in for rc-loaded env; `--no-augment-path` escape hatch
  (mutually exclusive with `--login`).
- AI tiers: `succeeded` / `differed` / `failed` with majority-output
  detection.
- `--report --out PATH` markdown output.
- `--out-dir DIR` writes per-host stdout/stderr/json files.

The AICAP code was copy-pasted from `executable_pqsum`, making `fleet exec`
the **4th** Python consumer of `dot_config/shell/04_ai_agents.sh`. The
extraction TODO is now P2 — next AI-tooling change should land
`scripts/aisum/__init__.py` first.


**Related**: `scripts/fleet/{tmux,info,pueue}.py`, `dot_dotfiles/bin/executable_fleet`, `docs/this_repo/fleet-apply.md`, `docs/tools/pueue.md` (lessons learned about SSH PATH)

## Why

The user surfaced this need 2026-05-13 while reviewing `fleet pueue`:

> 然後是不是fleet加一個 可以方便我同時在多臺host上執行command並且等待收集結果的subcommand？

The existing `fleet tmux` / `fleet info` / `fleet pueue` are specialised probes — each runs a fixed bash blob and parses structured output. They don't help when the user needs ad-hoc command execution across the fleet (`pueue --version` everywhere, `df -h /` everywhere, `systemctl --user status pueued` everywhere).

This is the most common Ansible / parallel-ssh use case, but the user doesn't want ansible's overhead for one-shot commands. Fleet already has the asyncssh + semaphore + inventory plumbing — `fleet exec` is a thin wrapper that exposes it directly.

## Design — confirmed via AskUserQuestion (2026-05-13)

### Shape: argv list after `--`, not a shell string

```bash
fleet exec [OPTIONS] -- COMMAND [ARG...]
```

Examples:

```bash
fleet exec -- pueue --version
fleet exec -- df -h /
fleet exec --hosts ts_nas,jingle207 -- systemctl --user status pueued
fleet exec --serial -- ls -la /var/log/nginx/
```

**Rationale**: no shell expansion on the orchestrator side means no quoting / injection footguns. The argv is passed through asyncssh's `conn.run(argv_list)` (which uses execvp-style on the remote, no shell). For users who explicitly want pipes / globs / redirects, add `--shell bash|zsh|sh` to wrap the command in `bash -c "<reassembled string>"`.

**Trade-off accepted**: `fleet exec -- echo "hello world" | wc` doesn't pipe — the `| wc` is parsed by the LOCAL shell. Users wanting cross-host piping use `--shell`.

### PATH augmentation (same prelude as pueue)

`fleet exec` uses the SAME PATH-augmenting prelude lesson learned from `scripts/fleet/pueue.py`:

```
$HOME/.dotfiles/bin:$HOME/.cargo/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.linuxbrew/bin:$PATH
```

Without this `fleet exec -- pueue --version` finds no pueue on hosts where it lives in `/opt/homebrew/bin` or `~/.cargo/bin`. Same false-negative class as the original pueue probe bug.

**Flag**: `--no-augment-path` skips the prelude when the user explicitly wants the minimal SSH PATH (debugging "what does ssh see by default").

**Flag**: `--login` wraps the command in `bash -lc "..."` so the user's rc files load. Slower (~150-500ms per host) but matches "as if I SSH'd in and ran it". Caveat: `bash -lc` on hosts where the user's primary shell is zsh misses the zshrc-set PATH additions (cargo, pyenv, mise, conda init blocks) — limitation, not a bug.

### Render: table by default, `--json` for piping

Default rendering:

```
                          fleet exec — pueue --version
┏━━━━━━━━━━━━━━┳━━━━┳━━━━━━━━━━━━┳━━━━━━┓
┃ HOST         ┃ RC ┃ STDOUT     ┃   ms ┃
┡━━━━━━━━━━━━━━╇━━━━╇━━━━━━━━━━━━╇━━━━━━┩
│ self         │  0 │ pueue 4.0.1│  120 │
│ hanru_mac    │  0 │ pueue 4.0.2│  610 │
│ ts_nas       │  0 │ pueue 4.0.1│  990 │
│ jingle207    │  0 │ pueue 4.0.2│  450 │
│ david_ubuntu │  0 │ pueue 4.0.2│  720 │
└──────────────┴────┴────────────┴──────┘
```

- `STDOUT` shows the first line, truncated to terminal width.
- Non-zero exit codes render the RC cell in red; stdout truncates to make room for stderr's first line.
- Per-host SSH/timeout failures show `RC=N/A` and the error class.

`--json` emits a JSON array, one record per host:

```json
[
  {
    "host": "self",
    "rc": 0,
    "stdout": "pueue 4.0.1\n",
    "stderr": "",
    "elapsed_ms": 120
  },
  ...
]
```

`--out-dir DIR` writes per-host `DIR/<host>.stdout` + `DIR/<host>.stderr` + `DIR/<host>.json` (rc + elapsed). Useful for long outputs that don't fit the table.

### AI mode — `fleet exec --ai`

Confirmed in scope per AskUserQuestion 2026-05-13. Mirrors the `fleet pueue --ai` pattern: pipe the merged per-host JSON to a new prompt template (`AIEXEC_PREAMBLE`) that classifies hosts:

- **`succeeded`** — rc=0 AND stdout matches the cluster majority
- **`differed`** — rc=0 BUT stdout differs from the majority (e.g. different version, different config)
- **`failed`** — rc≠0 OR SSH/timeout error

Output JSON:

```json
{
  "command": "pueue --version",
  "majority_output": "pueue 4.0.2",
  "hosts": [
    {"host": "self",      "tier": "differed",  "summary": "pueue 4.0.1 (older — upgrade candidate)"},
    {"host": "hanru_mac", "tier": "succeeded", "summary": "pueue 4.0.2"},
    {"host": "ts_nas",    "tier": "differed",  "summary": "pueue 4.0.1 (older)"},
    {"host": "jingle207", "tier": "succeeded", "summary": "pueue 4.0.2"},
    {"host": "david_ubuntu", "tier": "succeeded", "summary": "pueue 4.0.2"}
  ],
  "fleet_summary": "3/5 hosts on pueue 4.0.2; self + ts_nas trailing on 4.0.1 — both upgrade candidates"
}
```

Implementation: lives in a new `dot_dotfiles/bin/executable_fleetexec-ai` (separate Python uv-script, **not** in `executable_pqsum` — different domain). OR: extract the existing AGENT_CONFIG / detect_agent / invoke_agent / cache_lookup helpers from `executable_pqsum` into a shared module **first** (`scripts/aisum/__init__.py`, per the existing TODO follow-up), then `executable_fleetexec-ai` imports from it. The shared-module refactor is already listed; doing it before adding the 4th consumer is the cleanest path.

`fleet exec --ai --report` emits markdown (mirrors `pqsum ai --report`).

### Where it sits

- `dot_dotfiles/bin/executable_fleet` — add `exec` to USAGE + dispatch dict
- `scripts/fleet/exec.py` — new module, ~150 LOC, mirrors `scripts/fleet/pueue.py` skeleton
- `dot_dotfiles/bin/executable_fleetexec-ai` (or shared module) — AI summarization
- `docs/this_repo/fleet-apply.md` — add `exec` row to subcommand table
- `docs/tools/` — new `fleet-exec.md` (+ zh-TW mirror)
- `mkdocs.yml` — nav entry

### Out of scope

- **Per-host write confirmations** (the `--clean` y/N model from pqsum) — `fleet exec` is "run this everywhere", any safety check is the user's job.
- **Long-running streaming output** — `fleet exec` captures completed stdout/stderr only. For watch / tail use `fleet tail` (apply-log specific) or a future `fleet stream`.
- **stdin passthrough** — `fleet exec --stdin file.txt -- some-cmd` would feed file.txt to each remote command's stdin. Plausible follow-up, not in v1.
- **Pty allocation** (`-t` over SSH) — non-interactive only in v1. Interactive commands (vim, less) don't fit the fan-out model.

## Promote when

At least two of these become true:

- (a) User runs the same command across hosts 3+ times in a row manually (`for h in hosts; do ssh $h cmd; done`).
- (b) The AICAP shared-module extraction lands (so adding the 4th AI consumer doesn't pay the duplication tax).
- (c) A specific cross-host audit need surfaces ("which hosts are running kernel 6.x?", "which have ssd?").

## Cross-references

- Cross-file invariants from this work (PATH augmentation, daemon protocol drift handling) live in `scripts/fleet/pueue.py` and should be copied into `scripts/fleet/exec.py` verbatim. If a future refactor extracts a shared `scripts/fleet/_ssh_probe.py` helper, both files become callers.
- The `--shell bash|zsh` flag is the same surface as Ansible's `ansible_shell_executable` — semantic parity acceptable.
- For users on hosts where pueue itself is the wrong version (jingle207's 4.0.1 vs 4.0.2 daemon drift), `fleet exec --ai -- pueue --version` would surface the mismatch as `differed` tier with version pinpointed. This is the audit use case (c) above.
