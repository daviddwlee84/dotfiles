# Add an MLflow Television (tv) channel

## Context

The user runs experiments against three MLflow backends — local `./mlruns` files, a local `sqlite:///mlflow.db`, and a LAN server at `http://192.168.222.207:15002/`. There is no current way to fuzzy-search experiments or runs from the terminal: the MLflow web UI is one tab, and `mlflow runs list` only emits a Rich-formatted text table (no JSON). The `mlflow` CLI is already installed via `dot_ansible/roles/python_uv_tools/defaults/main.yml:49` and the `mlflow-tracking` agent skill documents the three deployment modes, so the missing piece is an interactive picker.

We will add a `tv mlflow` channel that lists experiments / recent runs / experiment-scoped runs / registered models, previews each entity as JSON, and supports copying IDs and opening them in the browser when the tracking URI is HTTP. The helper is a single Python script using `mlflow.MlflowClient`, because it is the only backend strategy that handles file, sqlite, and HTTP URIs uniformly (REST API alone would skip 2 of 3 modes; CLI list output is not JSON).

## Approach

### Design decisions

- **Pure Python helper.** One `MlflowClient` against `MLFLOW_TRACKING_URI` (env-var-only, no aliases / no source-cycling presets). When the URI is unset, MLflow's own default (`file:./mlruns` in CWD) is used.
- **Helper layout = same as `super-productivity-source.sh`.** Channel TOML stays lean; helper handles preflight, hint rows on failure, and TSV emission. Cycles via separate source commands (Ctrl+S inside TV).
- **No `watch =`.** mlflow imports cost ~1–2s (pydantic + sqlalchemy); auto-refresh would be sluggish. Manual `Ctrl+R` reload is fine — experiments/runs change on the minute scale, not seconds.
- **Pydantic deprecation noise is suppressed** in the helper via `PYTHONWARNINGS=ignore` env + `warnings.filterwarnings("ignore", category=DeprecationWarning)` so stderr doesn't leak into source rows.
- **Drill-down via env var, not nested actions.** `runs-experiment` source reads `$MLFLOW_EXPERIMENT_ID`; if unset, it emits a single hint row pointing at the env var. An `alt-r` action re-execs `tv mlflow` with the highlighted experiment's id exported, giving a one-keystroke drill-down without state plumbing.

### Files to create

| Path | Role |
|---|---|
| `dot_config/television/cable/mlflow.toml` | Channel definition — 4 source modes, 2 preview modes, 5 keybindings/actions |
| `dot_config/television/executable_mlflow-source.py` | TSV emitter for source modes; preflight + hint-row on failure |
| `dot_config/television/executable_mlflow-preview.py` | JSON detail / metrics summary for preview |

Both helpers use `#!/usr/bin/env -S uv run --script` with PEP 723 inline deps pinning `mlflow>=3.4` (the version already installed). This keeps them invokable on any host where `uv` is present, even outside the `mlflow` uv tool's site-packages — consistent with how `executable_clash-parse.py` is structured (it's a `uv run --script` file too).

### Helper script behavior

`mlflow-source.py <mode>` where `<mode>` ∈ `experiments | runs-recent | runs-experiment | models`:

1. `os.environ.setdefault("PYTHONWARNINGS", "ignore")` + `warnings.filterwarnings("ignore")`.
2. Resolve `MLFLOW_TRACKING_URI`; if set, `mlflow.set_tracking_uri(...)`.
3. Preflight: `MlflowClient().search_experiments(max_results=1)`. On any exception emit one hint row:
   `0\t⚠ unreachable\t<scheme>\tCheck MLFLOW_TRACKING_URI=<uri> — <short err msg>` and exit 0.
4. Emit TSV per mode:
   - `experiments` → `<exp_id>\t📊\t<lifecycle>\t<name>\t<last_update_iso>`
   - `runs-recent` → `<run_id>\t<status_icon>\t<exp_name>\t<run_name|short_id>\t<start_iso>` (top 50 by `start_time` desc, across all experiments)
   - `runs-experiment` → same shape as `runs-recent` but filtered to `$MLFLOW_EXPERIMENT_ID`; hint row if env var unset
   - `models` → `<model_name>\t📦\t<latest_version_stage>\t<description_first_line>\t<last_updated_iso>`
5. Status icon mapping: `RUNNING`→`▶`, `FINISHED`→`✓`, `FAILED`→`✗`, `KILLED`→`■`, `SCHEDULED`→`○`.

`mlflow-preview.py <kind> <id>` where `<kind>` ∈ `experiment | run | model`:

- For `run`: pretty-print `client.get_run(run_id)` as JSON (params, metrics, tags, artifact_uri, status, timestamps). Two views via TV preview-cycle: full JSON, or metrics-only summary (last value per metric key).
- For `experiment`: pretty-print `client.get_experiment(exp_id)` + a short tail of its 5 most recent runs.
- For `model`: pretty-print `client.get_registered_model(name)` with latest versions.

Hint row case (`id == "0"`): preview emits `Help: set MLFLOW_TRACKING_URI=http://... or sqlite:///path/to/mlflow.db, then Ctrl+R to reload.`

### Channel TOML structure

Mirror `dot_config/television/cable/super-productivity.toml:57-118` exactly — same `[metadata]`, `[source]` (array of commands → Ctrl+S cycles), `[preview]` (array → Ctrl+F cycles), `[ui.preview_panel].size = 60`, `[keybindings]`, and per-action `[actions.*]` tables.

Source array (cycles in this order):

```
~/.config/television/mlflow-source.py experiments
~/.config/television/mlflow-source.py runs-recent
~/.config/television/mlflow-source.py runs-experiment
~/.config/television/mlflow-source.py models
```

Preview array (cycles in this order):

```
~/.config/television/mlflow-preview.py auto '{split:\t:0}' --view full
~/.config/television/mlflow-preview.py auto '{split:\t:0}' --view metrics
```

`auto` lets the preview script infer entity kind from id shape (uuid-like → run, integer → experiment, otherwise → model) — simpler than threading the source mode through.

Keybindings:

| Key | Action | Notes |
|---|---|---|
| `Enter` | `open-detail` | Full JSON in `less -R`, then "press Enter to exit" |
| `Ctrl+Y` | `copy-id` | Overrides TV's default (which copies the whole display row) |
| `Ctrl+O` | `open-browser` | No-op + message if URI is not `http(s)://` |
| `Alt+R` | `drill-runs` | Re-exec `MLFLOW_EXPERIMENT_ID=<id> tv mlflow` (only meaningful on experiment rows) |
| `Alt+J` | `dump-json` | Print JSON to terminal, paged |

`requirements = ["mlflow", "uv"]` in `[metadata]`. `uv` because the helpers are `uv run --script`; `mlflow` because that's the import target. `jq` is NOT a hard requirement — the Python helper does its own JSON formatting via `json.dumps(..., indent=2)` and colorizes with `rich` if available, plain otherwise.

### Reuse from the existing codebase

- Clipboard helper pattern: lift the `_clip` shell function verbatim from `dot_config/television/cable/super-productivity.toml:107` (pbcopy / wl-copy / xclip / OSC52 fallback chain). Already battle-tested across mac/Linux/SSH.
- Preflight / hint-row pattern: same shape as `executable_super-productivity-source.sh:55-70` — single row with id `0`, emoji marker, actionable hint.
- `uv run --script` shebang + PEP 723 frontmatter: see `executable_clash-parse.py` for the convention used in this repo.

### Files to modify

- `.claude/skills/mlflow-tracking/SKILL.md` — append a short "Browse from terminal: `tv mlflow`" pointer near the deployment-modes section. Optional, low priority.

### Files NOT touched (and why)

- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — `mlflow` is already pinned (no version bump needed).
- `CLAUDE.md` cross-file table — no MkDocs doc surface created, no new chezmoi prompt, no new shell alias / function, no new keybinding under `Ctrl+`/`Alt+` in the *shell* config (`Alt+R` is scoped to the TV channel context, which falls outside the `dot_config/{shell,zsh,bash}/` aliases / `docs/shells/keybindings.md` tables).
- `docs/shells/aliases.md` — no shell alias added (user opted against an alias).
- `README.md` — channel addition is not a new platform / role / setup step.

## Verification

1. **Schema lint** — open `mlflow.toml` in any TOML linter; ensure `{split:\\t:N}` placeholders survive (triple-quoted strings only where backslashes need it).
2. **Local file mode** —
   ```
   cd /tmp && mkdir -p mlrun-test && cd mlrun-test
   uv run python -c "import mlflow; mlflow.set_experiment('demo'); mlflow.start_run(); mlflow.log_param('x', 1); mlflow.end_run()"
   tv mlflow
   ```
   Expect: `demo` experiment listed under Ctrl+S source 1; one run under source 2.
3. **SQLite mode** —
   ```
   cd /tmp/mlrun-test && MLFLOW_TRACKING_URI=sqlite:///$PWD/mlflow.db tv mlflow
   ```
   Expect: empty list (fresh sqlite) → log one run → Ctrl+R → reappears.
4. **LAN HTTP server** —
   ```
   MLFLOW_TRACKING_URI=http://192.168.222.207:15002 tv mlflow
   ```
   Expect: real experiments from the user's earlier curl smoke (`Dev/PlainTextProgress_Test`, `WF_Proxy_Test`, …) under source 1. Ctrl+F should cycle full-JSON ↔ metrics-only previews. Ctrl+O should open the run/experiment in the system browser.
5. **Failure-path UI** —
   ```
   MLFLOW_TRACKING_URI=http://no-such-host:9999 tv mlflow
   ```
   Expect: single yellow hint row, no crash, no Python traceback leaking into the source view.
6. **Drill-down** — highlight an experiment row → `Alt+R` → TV re-launches scoped to that experiment → source 3 (`runs-experiment`) now shows real rows. Exit TV → original env restored.
7. **`tv channels`** lists the new entry with description.
8. **App-level validation** (per repo invariant "Validate app configs with the app, not just syntax") — `tv --version >/dev/null && tv mlflow --help 2>&1` to confirm TV parses the TOML cleanly; no error from the cable loader.
