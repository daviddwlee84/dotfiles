# Add `mlf` umbrella CLI for MLflow — phase 2: interactive TUI

## Context

Phase 1 shipped in commit `3882a4d`: the `mlf` umbrella binary with `tv`, `open`, `copy`, `plot`, `list`, `download` subcommands plus `Ctrl+B` in the `tv mlflow` channel. Today, bare `mlf` (no args) prints USAGE; users who want to *browse* MLflow data still have to drop into `tv mlflow` — a single-pane fuzzy picker that's good for one-shot lookups but doesn't show the run's full structure (params, metrics, artifacts, plot) at the same time, and can't drill into a metric history without exiting.

Phase 2 makes bare `mlf` open a **full Textual dashboard** — a multi-pane TUI that exposes everything the subcommands do but interactively, with simultaneous tree + preview + plot, and with one-key dispatch to `open/copy/plot/download`. This is a strict superset of `tv mlflow`'s functionality; the tv channel remains as the lightweight one-shot picker (the two UIs complement each other: tv = "I know what I want, fuzzy-find it fast"; mlf TUI = "I want to explore").

## Approach

### Trigger surface

| Invocation                | Behavior                                                    |
|---------------------------|-------------------------------------------------------------|
| `mlf` (no args)           | **Launch TUI** (changed from "print USAGE")                 |
| `mlf tui`                 | Alias for `mlf` no-args (explicit form for scripts)         |
| `mlf -h` / `mlf help`     | Print USAGE (USAGE updated to mention TUI on the first line)|
| `mlf <sub> [...]`         | Run subcommand directly (unchanged — automation path)       |

### TUI stack

`textual>=5.0`, added to the **PEP 723 inline-deps block** of `dot_dotfiles/bin/executable_mlf`. No `dot_ansible/roles/python_uv_tools/` change — consistent with the rest of the umbrella's deps (`tyro`, `rich`, `plotext`, `mlflow` are all inline-declared; `uv run --script` resolves on first invocation and caches in `~/.cache/uv`).

New module: `scripts/mlf/tui.py` (~400–500 LOC).

### Layout (target render)

```
┌─ MLflow @ http://192.168.222.207:15002 ── (mode: http) ──────┐
│ Sources              │ Selection: cb250b88...  (Run)         │
│ ▾ Experiments (5)    │ ┌─ Overview Params Metrics Plot ──┐   │
│   0  Default         │ │ run_name: vision-bert-v3        │   │
│   1  vision-train    │ │ status:   ✓ FINISHED            │   │
│   2  summarization   │ │ duration: 1h 23m                │   │
│ ▾ Runs (recent 50)   │ │ params (8):                     │   │
│   cb250b88…  ✓ done  │ │   lr: 1e-4                      │   │
│   da881a7e…  ✓ done  │ │ metrics (last):                 │   │
│ ▾ Models (3)         │ │   loss: 0.12                    │   │
│   vision-bert        │ │   acc:  0.94                    │   │
│   text-classifier    │ │ artifact_uri: s3://…            │   │
│   whisper-finetune   │ └─────────────────────────────────┘   │
├──────────────────────┴───────────────────────────────────────┤
│ http://192.168.222.207:15002 │ cb250b88 │ idle               │
└──────────────────────────────────────────────────────────────┘
 b:browse  y:copy  p:plot  d:download  j:json  /:filter  r:refresh  ?:help  q:quit
```

### Widgets

| Region        | Widget                       | Behavior                                                                                   |
|---------------|------------------------------|--------------------------------------------------------------------------------------------|
| Header        | `Header` (textual built-in)  | Title: `MLflow @ <tracking_uri>  (mode: file\|sqlite\|http)` — auto from `tracking_uri()`. |
| Left pane     | `Tree[str]`                  | Three top-level nodes (Experiments / Runs / Models). Lazy-load children on expand.        |
| Right pane    | `TabbedContent` with 6 tabs  | See "Tabs" below.                                                                          |
| Status bar    | `Static` (custom)            | `<tracking_uri> │ <selection_id> │ <spinner\|idle>`                                         |
| Footer        | `Footer` (textual built-in)  | Auto-rendered from `BINDINGS` list; dynamically reflects active screen.                    |

### Tabs (right pane)

| Tab name   | Widget                            | Source                                                                                          |
|------------|-----------------------------------|-------------------------------------------------------------------------------------------------|
| Overview   | `DataTable[(field, value)]`       | Selection-specific summary (run: name/status/dur/start; exp: name/lifecycle/artifact_location). |
| Params     | `DataTable[(key, value)]`         | `run.data.params` (sorted by key). Empty for experiment/model selection.                        |
| Metrics    | `DataTable[(key,last,min,max,n)]` | `run.data.metrics` keys × `get_metric_history` for stats. Async fetch per key.                  |
| Plot       | `SelectionList` + `Static`        | Multi-select metric keys above → `plotext.build()` rendered into the Static below.              |
| Artifacts  | `Tree[str]`                       | `client.list_artifacts(run_id, path=...)` — lazy-load by path on expand.                        |
| Tags       | `DataTable[(key, value)]`         | `run.data.tags` (filtered to drop `mlflow.*` internals; toggle with `T` to show all).           |

### Keybindings (in-app)

| Key            | Action                                                                                |
|----------------|---------------------------------------------------------------------------------------|
| `q` / `Esc`    | Quit (confirm prompt only if a download is in-flight).                                |
| `r`            | Refresh the active tree node (re-fetch its children from MLflow).                     |
| `/`            | Filter: focus a search `Input` that fuzzy-filters the tree's visible rows.            |
| `Enter`        | Drill: expand tree node OR focus right pane.                                          |
| `Tab` / `S-Tab`| Cycle right-pane tabs.                                                                |
| `b`            | Open selection in browser (HTTP guard preserved; reuses `open_id()` pure helper).     |
| `y`            | Copy selection id (reuses `copy_id()` pure helper).                                   |
| `p`            | Plot dialog: multi-select metric keys, re-render Plot tab on Apply.                   |
| `d`            | Download dialog: spawn `mlf download` subprocess, stream output to a `Log` widget.    |
| `j`            | Suspend Textual → pipe full JSON detail through `less -R` → resume.                   |
| `?`            | Help overlay listing all bindings (Textual `BINDINGS` reflected onto a modal).        |
| `T`            | Toggle internal-tag visibility in the Tags tab.                                        |

The single-letter mnemonics (`b`, `y`, `p`, `d`, `j`) intentionally mirror the `Ctrl+<letter>` keys already used by the `tv mlflow` channel — same mental model whether the user is in the lightweight picker or the heavy dashboard.

### Modal dialogs

**Plot dialog** (`p` on a Run row):
- `SelectionList[str]` populated from `run.data.metrics.keys()`.
- Default pre-selection: keys NOT starting with `system.` (training metrics over telemetry).
- Buttons: `[Apply] [Cancel]`.
- Apply → switch right pane to Plot tab, re-render `plotext.build()` with the selected keys + below-plot stats line per key. Reuses the **exact** per-key try/except + `skipped[]` loop from `scripts/mlf/plot.py` so one slow `system.*` metric can't abort the chart (lesson learned in phase 1).

**Download dialog** (`d` on a Model row):
- Inputs: `Input(model_name)` pre-filled, `Input(version|alias)` defaulting to `latest`, `Input(dest_path)` defaulting to `./<name>-<version>/`.
- Submit → `subprocess.Popen(["mlf", "download", f"{name}@{ver}", "--dest", dest], stderr=PIPE)`, stream lines into a `Log` widget below the inputs.
- On exit: print final absolute path into the StatusBar; close dialog.

### Data flow

- **Client**: single `MlflowClient` instance per app session, built lazily on first tree fetch via `make_client()` (from `scripts/mlf/__init__.py`). All env-default fast-fail timeouts (`MLFLOW_HTTP_REQUEST_TIMEOUT=5`, `MLFLOW_HTTP_REQUEST_MAX_RETRIES=1`) already in place from phase 1.
- **Top-level tree**: `_experiments(client, limit=200)`, `_runs(client, limit=50, exp_id=None)`, `_models(client, limit=200)` — **reuses the exact row-builders** from `scripts/mlf/list.py`. Same `Row` dataclass becomes the tree-node payload.
- **Expanding an Experiment node** → `_runs(client, limit=50, exp_id=<id>)` for its scoped runs.
- **Selecting a row** → single round-trip: `client.get_run(id)` / `get_experiment(id)` / `get_registered_model(name)`. Populates Overview/Params/Metrics/Tags from the response; Artifacts and Plot fetch separately on tab activation.
- **All I/O on `@work(thread=True)`** workers. Status bar spinner shows `fetching…` while pending; abortable with `Esc`.

### Error & empty states

- **Tracking URI unreachable on startup** → splash `Screen` shows: `MLFLOW_TRACKING_URI=<x>`, the exception class + first-line message, and `[r] retry  [q] quit`. The `MLFLOW_HTTP_REQUEST_TIMEOUT=5` default makes this visible within ~5s.
- **file:// backend** → Models tab body shows a hint `"Model registry unavailable for file: backend — switch to sqlite:/// or http(s):// to use the registry."` (matches the friendly fallback already in `mlf list models`).
- **Empty experiment** → tree leaf renders as `(no runs yet)`.
- **Run with zero metrics** → Plot tab shows a single-line hint, no dialog crash.
- **stdout not a TTY** (e.g. `mlf | cat`) → exit early with stderr message `mlf: TUI requires a terminal. Use 'mlf list ...' or 'mlf -h' for piped output.`

### Files to create

| Path                  | Role                                                                                                |
|-----------------------|-----------------------------------------------------------------------------------------------------|
| `scripts/mlf/tui.py`  | `class MLflowApp(App)`, splash screen, modal dialogs, workers. Entry: `main()` → `MLflowApp().run()`. |

### Files to modify

| Path                                | Change                                                                                              |
|-------------------------------------|-----------------------------------------------------------------------------------------------------|
| `dot_dotfiles/bin/executable_mlf`   | (1) Add `textual>=5.0` to PEP 723 deps; (2) Refactor `_dispatch_open` / `_dispatch_copy` to thin shims around new pure helpers `open_id(ident)` / `copy_id(ident)` (so the TUI can call them in-process without re-import overhead); (3) Change `main()` no-args branch from `print(USAGE); return 0` to `_dispatch_tui([])`; (4) Add `"tui": _dispatch_tui` to the dispatch dict; (5) Update USAGE preamble first line: ``Bare `mlf` (no args) launches the interactive TUI. Subcommands below bypass it.`` |
| `CLAUDE.md` (cross-file table)      | Add row: surface `scripts/mlf/tui.py` keybinding letters ↔ `dot_config/television/cable/mlflow.toml` Ctrl+letter bindings — both UIs share mnemonics (`b`, `y`, `p`, `d`, `j`), so changes to one should be mirrored in the other to preserve muscle memory. |

### Refactor required (load-bearing)

The current `_dispatch_open(args: list[str])` and `_dispatch_copy(args: list[str])` parse argv inline. The TUI needs in-process calls, not subprocess (to avoid the ~1s `import mlflow` cost per keystroke). Refactor to:

```python
def open_id(ident: str) -> int:    # pure: takes id, returns exit code
def copy_id(ident: str) -> int:    # pure: takes id, returns exit code

def _dispatch_open(args): return open_id(_first_arg(args, "open"))
def _dispatch_copy(args): return copy_id(_first_arg(args, "copy"))
```

No behavior change on the CLI surface. The TUI's `b` / `y` actions call the pure helpers directly with the currently-selected id.

### Reuse from existing codebase

- `scripts/mlf/__init__.py`: `make_client()`, `RUN_ID_RE`, `detect_kind()`, `ms_to_iso()`, `tracking_uri()`, `tracking_uri_is_http()` — all used as-is.
- `scripts/mlf/list.py`: `_experiments`, `_runs`, `_models`, `STATUS_ICON`, `Row` dataclass — used for tree population.
- `scripts/mlf/plot.py`: the per-key history fetch loop with try/except + `skipped[]` — extracted into a helper `fetch_histories(client, run_id, keys) -> (series, skipped)` that both the CLI plot subcommand AND the TUI Plot tab consume.
- `dot_config/television/executable_mlflow-preview.py`: field set + ordering for the Overview tab mirrors `--view full`'s JSON shape so the two UIs feel consistent to the eye.

### Files NOT touched (and why)

- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — `textual` is PEP 723 inline (matches phase 1 convention; `executable_fleet` declares `asyncssh`/`tyro`/`rich` the same way; ansible-pinning would only matter if other binaries shared `textual` system-wide).
- `dot_config/television/cable/mlflow.toml` — the lightweight tv channel stays as-is. The two UIs intentionally coexist: tv = fast picker, mlf TUI = dashboard. No new ctrl-binding to invoke the TUI from inside tv (would be circular; press `q` then run `mlf` for the upgrade).
- `justfile` — `mlf *ARGS:` recipe already passes args through transparently; no edit needed.
- `docs/` — adding a docs page is deferred until `docs/this_repo/mlf-cli.md` exists (a future pass). The CLAUDE.md cross-file row we ARE adding implies that surface as the next step, so the maintenance row isn't premature.

## Verification

1. **Cold start (file:// backend)** — `cd /tmp/mlruns_test && mkdir -p mlruns && mlf`. TUI launches; Experiments tab empty but no crash; Models tab shows friendly hint; `q` exits cleanly with terminal restored.
2. **Cold start (LAN tracking server)** — `MLFLOW_TRACKING_URI=http://192.168.222.207:15002 mlf`. Tree populates with 5 experiments within ~2s. Expand experiment 1 → runs load lazily. Highlight a run → Overview tab fills.
3. **Per-key actions**:
   - `b` on a run → browser opens to `/#/experiments/<exp>/runs/<run>` (URL also printed to status bar).
   - `y` on a run → 32-hex run_id in clipboard (paste-verify in another window).
   - `p` on a run → Plot dialog shows ~50 metric keys with non-`system.*` pre-selected; Apply → Plot tab renders multi-series plotext chart with stats line per key.
   - `d` on a model → Download dialog accepts `latest`/`@1`/`@Champion`; submit streams subprocess stderr live; final path displayed in status bar.
   - `j` on any row → terminal suspends, `less -R` shows JSON detail, `q` from less resumes TUI cleanly.
   - `/` → filter input narrows tree rows; `Esc` clears filter.
   - `r` → re-fetches active tree node.
   - `Tab` → cycles Overview→Params→Metrics→Plot→Artifacts→Tags.
   - `?` → help overlay; `Esc` dismisses.
4. **Splash on unreachable URI** — `MLFLOW_TRACKING_URI=http://127.0.0.1:1 mlf`. Splash visible within ~5s; `r` retries (still fails, same splash); `q` exits.
5. **Bypass paths unchanged** — `mlf -h` prints USAGE (does NOT launch TUI); `mlf plot <run>`, `mlf list runs`, `mlf list models --json | jq .`, `mlf open <id>`, `mlf copy <id>`, `mlf download <model>`, `mlf tv` all behave identically to phase 1 (commit `3882a4d`).
6. **TTY restore** — after `q` from TUI: cursor visible, no mouse-tracking escape leaks, `printf 'hello\n'` renders normally.
7. **Long-running download** — open download dialog, submit a model with sizable artifacts; verify the Log widget streams progress; verify `q` while in-flight prompts "Download in flight, quit anyway? [y/N]".
8. **Textual cold install** — on a fresh box (no `textual` in `~/.cache/uv`): first `mlf` invocation pauses ~3-5s for dep resolution, then launches; second invocation <1s. Confirms PEP 723 caching works.
9. **App validation** (per CLAUDE.md "Validate app configs with the app, not just syntax" invariant):
   - `python -m textual.cli console` in another pane while running `mlf` → no exceptions / warnings in the textual console output.
   - `mlf -h` ends with exit 0 (does NOT inadvertently launch the TUI when stdout is piped).
   - `mlf | cat` → friendly stderr message + exit 2; no half-rendered TUI escapes leak into the pipe.
10. **Linting** — `python -c "import ast; ast.parse(open('scripts/mlf/tui.py').read())"` exits 0. `ruff check scripts/mlf/tui.py` clean.

## Future scope (NOT in v1)

- Live tail (auto-refresh metrics of a `RUNNING` run on a 5s poll).
- Side-by-side diff of two runs (multi-select tree + comparison view).
- Registry write actions (promote version, set/delete alias).
- Embedded markdown rendering of `run.data.tags["mlflow.note.content"]`.
- Persistent UI state (`~/.cache/mlf/state.json`) — last source/tab/filter restored on next launch.
- `docs/this_repo/mlf-cli.md` page once the surface settles (CLAUDE.md cross-file row above will point here).
