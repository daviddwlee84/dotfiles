# SSH-config parser unification

**Status**: deferred. Three implementations exist on purpose; the shared-module
fix is blocked by a deploy-path constraint, not by effort.

**TODO entry**: `P2 [M] Unify the three SSH-config parsers`

## The three copies

| # | Where | What it does | Why it can't be one of the others |
|---|---|---|---|
| 1 | `dot_config/shell/96_ssh_setup.sh` → `_ssh_cfg_py` (a `python3 -` heredoc inside a deployed shell file) | **Surgical editor of human-written blocks**: find a `Host` block anywhere in the include tree and splice one `IdentityFile` line into it at the right indent. Also `ensure-include` / `add-include`. | Returns only the **first** matching block and discards ordering. `configd_reachable()` hardcodes `~/.ssh/config.d`. |
| 2 | `dot_config/television/cable/ssh-config.toml` (awk in the `[source]` command) | **Display lister**: emit `<file>\t<host>` for the picker, skipping wildcard patterns. | Not a parser of semantics — no `Include` recursion, no precedence. Rewriting it to shell out to `tsnet` would make a general SSH picker depend on a Tailscale tool. |
| 3 | `dot_dotfiles/bin/executable_tsnet` (a deployed uv PEP-723 script) | **Owns a delimited region no human writes.** Needs every alias in **true parse order** (shadow detection: ssh takes the first-obtained value for every keyword) and reachability of an **arbitrary path that may not exist yet** (`--out` can be anywhere). Also detects an `Include` scoped inside a `Host` block. | Neither #1 nor #2 can answer either question. |

## Why the obvious fix is blocked

The clean answer is one shared Python module under `scripts/`. But:

- **`scripts/**` is in `.chezmoiignore.tmpl`** — never deployed to `$HOME`.
- `tsnet` *could* reach it via the `_source_path()` trick `executable_fleet` uses
  (`chezmoi source-path` with a `~/.local/share/chezmoi` fallback).
- **`96_ssh_setup.sh` cannot.** It is a deployed *shell* file whose current
  failure mode is a graceful `return 127` → plain append when `python3` is
  absent. It runs during first-time setup on a fresh box, so giving it a hard
  dependency on the chezmoi source dir existing is a regression for exactly the
  scenario it was written for.

So unification needs a decision first: **is a deployed shared Python module worth
a new deploy path?** (e.g. `dot_dotfiles/lib/sshcfg.py` alongside
`dot_dotfiles/bin/`, imported by both `tsnet` and a rewritten `_ssh_cfg_py`.)
That is the spike, and it is why this is `[M]` and not `[S]`.

## What holds the line meanwhile

`tests/unit/tsnet_ssh_block.bats` contains a **cross-implementation agreement
test**: build a fixture tree under `$SSH_CFG_ROOT` and assert that `tsnet`'s
reachability verdict and `_ssh_cfg_py ensure-include` agree in all three states —
reachable, unreachable, and after `--add-include=yes` fixes it. Behavioural SSOT
rather than code SSOT. If you unify the implementations, that test should keep
passing unchanged; if it starts failing, the two have drifted.

`_resolve_includes` in `tsnet` carries a header comment naming all three copies,
and the hazard is recorded in `CLAUDE.md`'s in-house-CLI row.

## Related, also deferred

- **`tsnet sync-fleet`** — reconcile tailnet devices into
  `~/.config/fleet/machines.toml`. Needs a spike on the population mismatch
  first: the tailnet includes iOS handsets and other people's Macs, which are
  emphatically not fleet hosts, so "sync" is not a well-defined operation yet.
  Note `load_hosts()` in `scripts/fleet/apply.py` **silently drops unknown TOML
  keys** (`{k: v for k, v in merged.items() if k in host_fields}`), so any
  `tailscale_*` field would vanish unless the `Host` dataclass gains it.
