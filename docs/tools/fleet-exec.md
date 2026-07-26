# fleet exec — cross-host ad-hoc command runner

`fleet exec` runs an arbitrary command across every host in your fleet
inventory (`~/.config/fleet/machines.toml`), collects per-host stdout +
stderr + exit code, and renders a table — optionally with an AI-summarised
classification (succeeded / differed / failed).

Sister tools: [`fleet pueue`](pueue.md) for structured queue probing,
[`fleet tmux`](../this_repo/fleet-apply.md#fleet-tmux--cross-host-tmux-session-summary)
for tmux session summaries, [`fleet info`](../this_repo/fleet-apply.md)
for system metadata snapshots. All four share the same asyncssh + semaphore
plumbing from `scripts/fleet/apply.py`.

## Install

Deployed automatically by chezmoi as part of the `fleet` umbrella:

- `~/.dotfiles/bin/fleet` — the umbrella binary
- `~/.local/share/chezmoi/scripts/fleet/exec.py` — the implementation
  (resolved at runtime via `chezmoi source-path`)

No separate install step.

## Three execution modes (orthogonal flags)

The `--shell` / `--login` / `--no-augment-path` flags are independent and
compose freely. Defaults bias for safety (no shell expansion) and speed
(no rc-file load).

| Mode | Wire format | When to use |
|------|-------------|-------------|
| **Default (argv list)** | `<argv shlex-quoted>` via `sh -c` on remote | Most ad-hoc commands. No globs, pipes, or `$VAR` expansion. Safe by construction. |
| `--shell bash` | `bash -c '<argv space-joined>'` | When you need pipes (`\|`), globs (`*`), redirects (`>`), `&&`/`;` chains, or `$VAR` interpolation. |
| `--shell zsh` | `zsh -c '<...>'` | Zsh-specific syntax (`${(...)}`, `=~`, etc.). |
| `--login` | `bash -lc '<quoted argv>'` (or `<shell> -lc`) | Tools needing rc-loaded env: `nvm`, `mise`, `pyenv`, `conda activate`, shell aliases/functions. Slower (~150-500ms rc-load per host). |
| `--no-augment-path` | Direct argv, no PATH prelude | Debugging "what does SSH see by default" on this host. Mutually exclusive with `--login`. |

Combinations:

```bash
fleet exec -- pueue --version                       # argv default
fleet exec --shell bash -- 'cat *.log | grep ERR'   # shell for pipe + glob
fleet exec --login -- pueue --version               # rc-loaded env
fleet exec --login --shell zsh -- 'conda activate myenv && python -V'
fleet exec --no-augment-path -- echo "\$PATH"       # raw SSH PATH
```

`--` is the standard wrapper-CLI separator (same pattern as `ssh`, `docker
run`, `cargo run`, `pytest`). Everything after `--` is opaque to fleet's
own option parser, so inner-command flags like `--version` or `-c` never
collide with fleet's flags.

## PATH augmentation

Like [`fleet pueue`](pueue.md), this command prepends a fixed PATH prelude
on every host so user-installed binaries are visible to the
non-interactive SSH shell:

```
~/.dotfiles/bin → ~/.cargo/bin → ~/.local/bin → ~/bin →
/opt/homebrew/bin → /usr/local/bin → /home/linuxbrew/.linuxbrew/bin →
~/.linuxbrew/bin → $PATH
```

Order favours package-manager dirs (`~/.cargo/bin`, `~/.local/bin`) over
legacy `~/bin` so a stale download in `~/bin` doesn't shadow a fresher
`cargo install` of the same tool. `--no-augment-path` skips the prelude;
`--login` bypasses it (login shells load PATH from rc files instead).

This is a known divergence from your interactive shell's PATH order — see
[pueue.md § PATH augmentation](pueue.md) for the full rationale.

!!! warning "Maintainers: the prelude is duplicated in two files"

    `scripts/fleet/exec.py:_PATH_PRELUDE` and `scripts/fleet/pueue.py:_REMOTE_CMD`
    each embed their own copy of the order above. They **must** stay in sync —
    editing one alone makes `fleet exec` and `fleet pueue` disagree about which
    binary they find on the same host, with no error to point at it.

## AI summary mode

`fleet exec --ai` pipes the merged per-host JSON through the configured
LLM agent (`opencode` → `claude` → `codex` → `cursor-agent` priority, per
`dot_config/shell/04_ai_agents.sh`). The LLM classifies each host:

| Tier | Glyph | Meaning |
|------|-------|---------|
| `succeeded` | 🟢 | rc=0 AND stdout matches cluster majority |
| `differed` | 🟡 | rc=0 BUT stdout meaningfully differs (version drift, config drift, OS-specific output) |
| `failed` | 🔴 | rc≠0 OR SSH/timeout error |

Example output:

```
🌐 4 hosts on pueue 4.0.2, ts_nas lagging on 4.0.1 — consider upgrading NAS

majority: pueue 4.0.2

🟢 succeeded (4)
  self            rc=0     pueue 4.0.2 — matches cluster majority
  hanru_mac       rc=0     pueue 4.0.2 — matches cluster majority
  jingle207       rc=0     pueue 4.0.2 — matches cluster majority
  david_ubuntu    rc=0     pueue 4.0.2 — matches cluster majority

🟡 differed (1)
  ts_nas          rc=0     pueue 4.0.1 — one minor version behind
```

### Markdown reports

`fleet exec --ai --report --out PATH` emits a markdown document with
Summary / Succeeded / Differed / Failed sections plus per-host raw outputs
in a collapsible details block. Useful for sharing audit results, dropping
into commit messages, or archiving point-in-time fleet snapshots.

### Cache

Results cache at `~/.cache/fleet-exec/<host>-<prompt_hash>.json` (TTL
`FLEETEXEC_MIN_REFRESH_INTERVAL` seconds, default 120). The cache key is a
SHA of `(prompt + per-host stdout/stderr/rc)` — `elapsed_ms` is excluded
from the hash so identical command outputs reuse cache regardless of SSH
timing variance.

Force refresh: `fleet exec --ai --refresh -- ...`.
Skip cache entirely: `fleet exec --ai --no-cache -- ...`.
Inspect what would be sent without calling the LLM: `fleet exec --ai
--dry-run -- ...`.

## Output formats

```bash
fleet exec -- date                       # Rich table (default)
fleet exec --json -- date                # JSON array of per-host records
fleet exec --out-dir /tmp/exec-out -- df # per-host .stdout/.stderr/.json files
fleet exec --full-output -- df -h /      # table + per-host blocks below
```

The default table shows the **first line** of stdout, truncated to
terminal width. For commands with multi-line output (`df -h`, `ps -ef`,
`systemctl status`), `--full-output` or `--out-dir` are usually what you
want.

## Subset selection

```bash
fleet exec --hosts self,ts_nas -- pueue --version    # include subset
fleet exec --exclude jingle207 -- pueue --version    # exclude one
fleet exec --serial -- pueue --version               # one host at a time (debug)
fleet exec --max-parallel 4 -- pueue --version       # cap concurrency
```

Default parallelism is `min(8, len(hosts))`. SSH connect timeout: 15s.
Per-command timeout: 60s (override with `--command-timeout`).

## Exit code

`fleet exec` exits with `min(N_failed, 125)` where `N_failed` counts hosts
with rc≠0 OR SSH/timeout error. Useful for CI:

```bash
fleet exec --hosts production -- systemctl is-active myservice || alert.sh
```

## Common audit recipes

```bash
# Version drift audit
fleet exec --ai -- pueue --version
fleet exec --ai -- python3 --version
fleet exec --ai -- chezmoi --version

# Disk pressure check
fleet exec --ai -- df -h /

# Daemon health
fleet exec --shell bash -- 'systemctl --user is-active pueued 2>/dev/null || launchctl list | grep pueue'

# Find heavyweight processes
fleet exec --shell bash -- 'ps aux | sort -k 4 -r | head -5'

# Confirm a file deployed everywhere
fleet exec -- test -f ~/.config/fleet/machines.toml

# Kernel audit (Linux only — macOS hosts will show "failed")
fleet exec --ai -- uname -r
```

## Troubleshooting

- **`not-installed` for a tool that IS installed**: the SSH non-interactive
  shell has a minimal PATH. `--login` should expose all user-installed
  tools (slower); the default PATH prelude covers the common locations
  but not arbitrary ones.
- **`bash -lc` doesn't see my conda init**: zsh-only PATH additions don't
  load under `bash -lc`. Use `--login --shell zsh` instead.
- **AI mode hangs**: `fleet exec --ai --dry-run -- ...` prints the prompt
  without calling the LLM. If the prompt looks fine, the issue is upstream
  (agent not on PATH, API key, etc.).
- **AI returns garbage / non-JSON**: re-run with `--refresh`; if persistent,
  fall back to `--json` and post-process manually.
- **`--clean` doesn't exist here** (unlike `pqsum ai`): `fleet exec` is for
  generic commands; any safety check is the user's responsibility. To
  delete files cluster-wide use `fleet exec --shell bash -- 'rm ...'`
  knowingly.

## Cross-file invariants

Adding new flags or changing output schemas requires touching:

1. `scripts/fleet/exec.py` — primary implementation
2. `dot_dotfiles/bin/executable_fleet` — USAGE block + `_dispatch_exec`
3. `docs/this_repo/fleet-apply.md` — subcommand row
4. `docs/tools/fleet-exec.md` (+ zh-TW mirror) — this page

When adding a new AI agent, this script becomes the 4th Python consumer
of `dot_config/shell/04_ai_agents.sh` — see
[CLAUDE.md](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md)
AI-agent row.
