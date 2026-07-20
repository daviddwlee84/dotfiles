# `appsrc tui` (Textual) shows an empty table / hangs after "scanning…"

**Symptoms** (grep this section):

- `appsrc tui` opens, shows the `Name  Source  Kind  Size  Path` header, but the
  table stays **empty** — no rows ever appear, even after 10-20s.
- `tv appsrc` shows `0 / 0` results / "Select an entry to preview" (empty),
  while `appsrc scan` in a plain shell works fine (prints 2266 items).
- Debug log (`APPSRC_TUI_DEBUG=/tmp/x appsrc tui`) shows the worker reached
  `ctx built -> inventory` (or a random `cli 1500/2193 :: …`) and then **stops** —
  no `inventory=N`, no traceback, the app doesn't crash.
- Intermittent: a headless `App.run_test()` pilot populates 2276 rows every time,
  but the real terminal stalls at a **different** subprocess each run.

**First seen**: 2026-07 building the `appsrc tui` dashboard (`dot_dotfiles/bin/executable_appsrc`).
**Affects**: any Textual TUI whose `@work(thread=True)` worker calls **blocking
`subprocess.run` / `subprocess.Popen`** — especially many of them (a scan spawns
thousands: `brew`, `mdls`, `codesign`, `pkgutil`, `go version`, `du`). `mlf`'s
TUI never hit this because its worker does **HTTP** (mlflow client), not subprocess.
**Status**: fixed — the TUI shells out **once** to `appsrc scan/size --json` via
**asyncio-native** subprocess (no thread, no blocking subprocess in-thread).

## Root cause

Running blocking `subprocess.run` inside a Textual **worker thread**
(`@work(thread=True)`) intermittently **deadlocks** under Textual's asyncio event
loop. The main thread's asyncio child-watcher and the worker thread's own
`waitpid` race over reaping the child's exit — the worker's `subprocess.run`
blocks forever on a child that was already reaped (or vice-versa). It's
probabilistic per call, so a scan that forks **thousands** of children hangs
almost every real run, while the headless `run_test()` loop (different timing /
no raw tty) usually slips through — which is why a pilot "passes" but the real
terminal is dead. `stdin=subprocess.DEVNULL` does **not** fix it (it's the
child-reaping race, not a tty-read block).

## Fix / Prevention

- **Never call blocking `subprocess.run` from a Textual `@work(thread=True)`
  worker.** Use an **async** worker (`@work` on an `async def`, no `thread=True`)
  and `asyncio.create_subprocess_exec(...)` + `await proc.communicate()` — the
  loop reaps its own children, no race.
- Do the heavy work in **one** child process, not thousands: the `appsrc tui`
  worker runs `[sys.executable, _SELF, "scan", "--kind", K, "--json"]` (and
  `size --path … --json` for detail), then parses JSON into dataclasses
  (`_rec_from_dict`). The child does all the `brew`/`mdls`/`du` forks
  **synchronously in its own process** (no asyncio) → reliable. Bonus: reuses the
  exact CLI logic + cache, zero TUI/CLI divergence.
- `_SELF = os.path.abspath(__file__)`; re-invoke with `sys.executable` (the uv
  script venv that already has the deps) — no `uv run` re-resolution.
- Always set `stdin=DEVNULL` on helper subprocesses anyway (belt-and-braces
  against a child that opens the controlling tty).
- Also force `HOMEBREW_NO_AUTO_UPDATE=1` at module load — a `brew` call that
  triggers an auto-update on the aliyun mirror can hang for minutes (see
  [`homebrew-aliyun-autoupdate-hang`](homebrew-aliyun-autoupdate-hang.md)); deadly
  inside any worker.

## How to validate a TUI without a real TTY

`App.run_test()` (async pilot) mounts the app headlessly and pumps the loop with
`await pilot.pause()`; poll `app._records` / `table.row_count` to assert the
worker populated. **Caveat learned here:** the pilot's timing masks the
thread-subprocess race, so it is necessary but **not sufficient** — also drive
the real thing in a **tmux PTY** (`tmux new-session -d … ; send-keys "appsrc tui"
; sleep ; capture-pane`) and confirm rows actually render across several runs.

## Related

- `dot_dotfiles/bin/executable_appsrc` — `_tui_app` async workers `_scan`/`_size_view`/`_detail`.
- [`docs/tools/appsrc.md`](../docs/tools/appsrc.md) — the CLI + TUI.
- [`homebrew-aliyun-autoupdate-hang.md`](homebrew-aliyun-autoupdate-hang.md) — the brew-hang half.
- CLAUDE.md `appsrc` invariant row — the tv-channel ↔ TUI mnemonic mirror.
