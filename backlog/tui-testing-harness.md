# TUI E2E testing harness — Textual Pilot for `mlf` + pexpect/pyte for binaries

**Status**: P3 direction decided, execution deferred
**Effort**: M (mlf Pilot slice) → L (with pexpect helper + CI job)
**Related**: `TODO.md` · `dot_dotfiles/bin/executable_mlf` · `scripts/mlf/tui.py` · `dot_dotfiles/bin/executable_agent-warmup` (prior art) · `tests/unit/*.bats` (existing test model)

## Context

2026-07 — the ask was: *"maybe install `shell-use` (Microsoft's 'Playwright for the
terminal') so we can E2E-test our TUI executables?"* Researched shell-use, the
broader "terminal Playwright" landscape, and what TUIs this repo actually has.

Conclusion up front: **do NOT adopt `shell-use` into managed config yet**, and it
isn't even the right tool for what we have. The repo has exactly **one** genuine
full-screen TUI — `mlf` (Python **Textual**) — and Textual's own test harness
beats a generic PTY driver for it. Direction chosen (Textual Pilot + a thin
pexpect/pyte helper); user deferred building it this session ("先記下來").

## Investigation

### What `shell-use` actually is (github.com/microsoft/shell-use)

Real, MIT-licensed, genuinely "Playwright for the terminal": a native **Rust** CLI
+ **background daemon** + embedded (alacritty-based) emulator that spawns its own
PTY. Drives keyboard **and mouse** (`mouse click --on-text "OK"`), `wait
text|idle|exit`, `expect text|exit-code|output|snapshot` (Playwright-style
`__snapshots__/NAME.snap`), per-cell fg/bg inspection, SVG screenshots, always-on
asciinema recording. CLI + Python (`async with ShellUse()`) + Node/Bun/Deno
clients. Stable exit-code taxonomy (0 ok / 1 assert / 2 usage / 3 no-session / 4
daemon / 5 internal) + a generated `agent-context` JSON contract. Runs headless
(only the live `monitor` view needs a real TTY).

**Why it's a poor fit for this repo right now:**

- **Pre-1.0, self-declared WIP.** Latest `v0.0.1-beta.3` (2026-06-29), single
  maintainer (cpendery, of inshellisense). README verbatim: *"Work in progress …
  commands and behavior may change between releases & installation instructions
  may not yet work."* No API/CLI stability guarantee — directly conflicts with
  this repo's low-churn mandate.
- **Install is awkward to pin.** Nonstandard `brew tap microsoft/shell-use
  https://github.com/microsoft/shell-use` (not homebrew-core), or raw GitHub
  release asset whose naming is still churning (same trap as the SpecStory
  asset-naming lesson in repo memory). winget is Windows-only. Version string
  differs per ecosystem (npm `0.0.1-beta.3` vs PyPI `0.0.1b3`).
- **Extra moving part.** Persistent background daemon + `~/.shell-use/` state/log
  dir = more failure surface than a stateless CLI.
- **Snapshot/expect assertions churn** as the emulator/rendering shifts pre-1.0.

### What we'd actually be testing (repo scan)

**Only one genuine full-screen TUI exists:** `mlf` — `class MLflowApp(App)` in
`scripts/mlf/tui.py` (Python **Textual** ≥5.0, ~60KB, + rich/plotext), launched by
bare `mlf` / `mlf tui`. ~30 `Binding()`s (q / `/` filter / r / t / b / y / p / d /
j / 1-6 tabs + vim hjkl/g/G). Everything else is NOT a full-screen TUI:

| Executable | Shape | Interactive surface |
|---|---|---|
| `fleet`, `yth` | tyro line CLI | delegate picker to Television (`tv fleet-hosts` / `tv yth`) — lives in tv config, not their code |
| `dotcfg` (→ `dotfiles_init.py reconfigure`) | `questionary`/prompt_toolkit wizard | secondary PTY/expect candidate (line wizard, not full-screen) |
| `pqsum --clean` | rich + `input()` y/N loop | expect-style prompt target |
| `mi-router`/`reyee`/`sms` | tyro + rich + getpass | credential prompt only; need live routers → poor E2E targets |
| `x`, `ping-monitor`, `sesh-preview` | bash | non-interactive; `x` already has `tests/unit/x_cli.bats` |

**No test infra to build on:** tests today are **bats** (`just bats` →
`tests/unit/*.bats`) + docker smoke (`just test` / `check-all`). `pyproject.toml`
declares no pytest config; the only pytest suite is scoped to the
`agent-history-hygiene` skill. `.github/workflows/` has only `docs.yml` — no test
CI job. So a Python PTY/Pilot harness is **greenfield**: no runner, no dev-deps
group, no CI stage.

**Prior art already in-repo:** `agent-warmup` drives the interactive `claude` TUI
via a detached tmux session (dedicated socket, `send-keys` + Enter, teardown) —
i.e. we currently PTY-drive TUIs through **tmux**, not a PTY library. Also: every
`bin/executable_*` Python CLI is PEP 723 self-bootstrapping, so `mlf` already
pulls `textual>=5.0` itself — a Pilot test can exercise it without ansible having
run, **but must be invoked from the chezmoi source dir** because `tui.py` imports
`scripts.mlf.*`.

## Options considered

Split by ownership — one toolchain for our own Textual app, one for arbitrary
binaries.

| Layer | Pick | Why | Rejected alt |
|---|---|---|---|
| **Our `mlf` Textual app** | **Textual `Pilot` + `pytest-textual-snapshot`** | First-party, mature, fully headless/in-process (no PTY, no daemon), deterministic. `async with app.run_test() as pilot:` → `pilot.press()/click()/pause()`; `snap_compare()` SVG regression, baseline via `pytest --snapshot-update`. Tests `mlf` *better* than any black-box driver. | shell-use / terminalcp (overkill, PTY flakiness, churn) |
| **Arbitrary 3rd-party TUI binaries** | **pexpect + pyte** | Boring-stable bedrock (pexpect v4.9, ISC, ~15yr; Unix-only = fine for our mac/Linux fleet). pexpect drives the real PTY; pyte reconstructs the screen grid → assert cells/colors/regions. Every newer Python "terminal Playwright" (tuiwright, pytest-tuitest, mcp-tui-test) is just this stack with a nicer API. | shell-use (beta/daemon), hand-rolling raw PTY |
| **Optional agent/ergonomic layer** | terminalcp (MIT, v1.3.3, MCP+CLI+JS) *or* shell-use — only when its specific features (per-cell, built-in snapshot, Windows) are needed | Not a base. terminalcp slots into existing agent/MCP tooling for interactive debugging | making either the foundation |
| **Watch-list (too new)** | `tuiwright` (v0.1, 0 stars — Pilot-like pytest API over ptyprocess+pyte+snapshots; exactly the desired ergonomics), `pytest-tuitest` (v0.1, pyte, asserts colors) | Re-evaluate in ~6-12mo; could replace the hand-rolled pexpect+pyte helper | standardizing on them now |

VHS (`charmbracelet/vhs`, ~20k stars) is a complement for demo GIFs + coarse
`Output golden.ascii` golden-text snapshots, not an assertion framework.

## Implementation sketch (when picked up)

Slice 1 — `mlf` Pilot tests (M):

1. Dev-deps: `textual[dev]` + `pytest` + `pytest-textual-snapshot` (+ `pytest-asyncio`).
   No repo-wide pytest group exists — decide: a `[dependency-groups]`/`[tool.uv]`
   dev group in `pyproject.toml` run via `uv run pytest`, vs a PEP723 test runner.
2. `tests/` pytest tree (sibling of bats `tests/unit/`); `conftest.py` must make
   `scripts.mlf.*` importable (run from chezmoi source-path; add repo root to
   `sys.path` or set `pythonpath`). Fix terminal size via `run_test(size=(cols,rows))`.
3. A few Pilot tests: launch, key bindings (filter `/`, tab switch 1-6, quit `q`,
   vim `j`/`G`), modal open/close; `snap_compare()` baselines for the main screen.
   Mock MLflow client (no live tracking server in CI).
4. `just` recipe (`just pytest` / fold into `check-all`); optional `.github/workflows`
   test job (mind the "no test CI today" gap).

Slice 2 — pexpect/pyte helper (pushes to L): a thin `tests/lib` driver
(spawn → send keys → pyte-render → assert screen/cells) for black-box binaries;
model the tmux-driver ergonomics already proven by `agent-warmup`.

Cross-file note: adding pytest/textual **test** deps is a dev-tooling change, not a
runtime tool install — it does **not** trigger the `tool-managers.md` A–Z row rule
(that's for installed user tools). If a pexpect/pyte **CLI** ever ships as
`bin/executable_*`, then the completion + docs mirror rules apply.

## Current blocker / open questions

- Greenfield pytest infra: where do repo-wide dev-deps live (uv dev group vs
  PEP723 runner)? First pytest suite outside a skill → sets the pattern.
- CI: no test job exists; decide whether Pilot/snapshot tests run in `docs.yml`'s
  sibling or a new workflow (snapshot HTML report as artifact).
- `scripts.mlf.*` import coupling means tests only run from the chezmoi source
  dir — acceptable, but document it in the conftest.

## Decision

`2026-07` — **shell-use declined for managed config** (pre-1.0 beta, unstable
CLI/install, daemon, mismatched to our single Textual TUI). **Direction chosen:**
Textual `Pilot` + `pytest-textual-snapshot` for `mlf`; pexpect+pyte thin helper for
arbitrary binaries. **Execution deferred** at user request. Revisit shell-use only
after a stable **1.0** with pinnable, consistently-named release assets — and even
then only for the specific niches (per-cell color assertions, mouse-on-text,
Windows) Pilot/pexpect don't cover.

## References

- shell-use: <https://github.com/microsoft/shell-use> (v0.0.1-beta.3, 2026-06-29)
- terminalcp: <https://github.com/badlogic/terminalcp>
- Textual testing / Pilot: <https://textual.textualize.io/guide/testing/> · `pytest-textual-snapshot`
- pexpect <https://pexpect.readthedocs.io/> · pyte <https://github.com/selectel/pyte>
- Watch-list: tuiwright, pytest-tuitest (both v0.1, 2026)
- Sibling local-first Textual tool: `mlf` (`scripts/mlf/`, `tv mlflow`); in-repo TUI-driver prior art: `agent-warmup`
