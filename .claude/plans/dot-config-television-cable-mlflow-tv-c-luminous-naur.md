# Add an `mlf` umbrella CLI for MLflow

## Context

The `tv mlflow` channel landed in commit `81358eb` and works well for fuzzy-search across the three backends (file / sqlite / http). But several MLflow workflows don't fit a picker:

- **Terminal metric plots** — quickly eyeball a loss curve without leaving the shell or spinning up `mlflow ui`.
- **Browser deep-links** — given `MLFLOW_TRACKING_URI=http://192.168.222.207:15002`, jumping to `…/#/experiments/1/runs` or `…/#/experiments/1/runs/cb250b88…` should be one command, not a manual URL paste.
- **Quick clipboard** — copying a run hash to paste into a notebook / PR description.
- **Model download** — pulling a registered model's artifacts locally for inference or smoke-testing.
- **One-shot listings** — piping experiments / runs / models through `jq` for scripted workflows.

These all share a common substrate: `mlflow.MlflowClient` against the configured URI. The cleanest home is an umbrella CLI named **`mlf`** (short for mlflow, no collision with the real `mlflow` CLI or the Apple MLX framework) in `dot_dotfiles/bin/`, structured the same way as the existing `fleet` umbrella (commit `1db2807`). The umbrella also exposes a thin `mlf tv` subcommand so the tv channel is discoverable from one entry point.

Separately, inside `tv mlflow`, **`Ctrl+B`** is added as a second binding for the existing `open-browser` action — `Ctrl+O` stays as the canonical key, but `Ctrl+B` is the muscle-memory default many users reach for ("B for browser"). Enter behavior is unchanged.

## Approach

### Design decisions

1. **Name**: `mlf` — three letters, mnemonically maps to "mlflow" without shadowing the real `mlflow` CLI in `~/.local/bin/` (uv tool install).
2. **Architecture**: mirror the `fleet` umbrella verbatim. Thin dispatcher in `dot_dotfiles/bin/executable_mlf` with `_dispatch_<sub>()` functions; heavier subcommands (`plot`, `list`, `download`) delegate to modules in `scripts/mlf/` using `tyro.cli()`. Lightweight wrappers (`tv`, `open`, `copy`) stay inline.
3. **PEP 723 deps**: declared inline at the top of `executable_mlf`: `mlflow>=3.4`, `tyro>=0.9`, `rich>=13.9`, `plotext>=5.2`. No changes to `dot_ansible/roles/python_uv_tools/` — consistent with how `executable_fleet` declares `asyncssh`/`tyro`/`rich`.
4. **Source-dir discovery**: copy `_source_path()` verbatim from `executable_fleet:67-89` (chezmoi source-path → `~/.local/share/chezmoi` fallback). Required to locate `scripts/mlf/` from any cwd.
5. **Enter behavior in `tv mlflow`**: unchanged. The new `Ctrl+B` aliases the existing `[actions.open-browser]` action — both `Ctrl+O` and `Ctrl+B` trigger the same shell command.
6. **No JSON-output gymnastics in the umbrella**: each `mlf list <kind>` subcommand has its own `--json` flag rather than threading one through the dispatcher.

### Subcommand surface (v1)

| Subcommand | Purpose | Lives in |
|---|---|---|
| `mlf tv [...]` | exec `tv mlflow` (passes argv + env through) | inline in `executable_mlf` |
| `mlf open <id>` | open browser to the right URL (auto-detects kind) | inline in `executable_mlf` |
| `mlf copy <id>` | copy id to clipboard (pbcopy / wl-copy / xclip / OSC52) | inline in `executable_mlf` |
| `mlf plot <run_id> [metric...] [--width N] [--height N]` | plotext line plot of metric histories | `scripts/mlf/plot.py` |
| `mlf list <experiments\|runs\|models> [--limit N] [--experiment ID] [--json]` | rich table or JSON listing | `scripts/mlf/list.py` |
| `mlf download <model_name>[@<alias\|version>] [--dest DIR]` | resolve via registry + `mlflow.artifacts.download_artifacts()` | `scripts/mlf/download.py` |
| `mlf -h` / `mlf <sub> -h` | usage | inline |

### Files to create

| Path | Role |
|---|---|
| `dot_dotfiles/bin/executable_mlf` | Umbrella dispatcher (PEP 723 shebang, `_dispatch_<sub>` dict, `USAGE` string) |
| `scripts/mlf/__init__.py` | Shared helpers: `make_client()`, `detect_kind(id)`, `ms_to_iso(ms)`, `tracking_uri_is_http()` |
| `scripts/mlf/plot.py` | Terminal metric plot (tyro args dataclass + plotext) |
| `scripts/mlf/list.py` | Rich-table / JSON listings (tyro args dataclass) |
| `scripts/mlf/download.py` | Model + artifact download (tyro args dataclass) |

### Files to modify

| Path | Change |
|---|---|
| `dot_config/television/cable/mlflow.toml` | Add `ctrl-b = "actions:open-browser"` in `[keybindings]`. No new action body. Update the top-comment keybinding table to mention `Ctrl+B`. |
| `justfile` | Add `mlf *ARGS:` recipe wrapping `./dot_dotfiles/bin/executable_mlf`, placed adjacent to the existing `fleet *ARGS:` block (around `justfile:468`). |

### Helper behavior (per subcommand)

#### `mlf tv [args...]`
```python
def _dispatch_tv(args: list[str]) -> int:
    tv = shutil.which("tv")
    if not tv:
        print("mlf: `tv` (television) not in PATH", file=sys.stderr)
        return 2
    return subprocess.call([tv, "mlflow", *args])
```
Pure exec; argv (e.g. `--source-command "…"`) and env (e.g. `MLFLOW_TRACKING_URI`) pass through untouched.

#### `mlf open <id>`
- Auto-detect kind via `detect_kind(id)` (32-hex → run; `.isdigit()` → experiment; else → model). Same regex / shape used by `executable_mlflow-preview.py:42-60`.
- Read URI via `mlflow.get_tracking_uri()`; bail with friendly error to stderr (exit 1) when not `http(s)://`.
- For runs: roundtrip `client.get_run(run_id).info.experiment_id` to construct `/#/experiments/<exp_id>/runs/<run_id>`.
- For experiments: `/#/experiments/<exp_id>`.
- For models: `/#/models/<name>`.
- Open via `webbrowser.open(url)` (handles mac `open`, linux `xdg-open`, WSL). Print URL to stderr as a diagnostic fallback.

#### `mlf copy <id>`
- Pure Python clipboard chain: `pbcopy` → `wl-copy` → `xclip -selection clipboard` → OSC52 escape to `/dev/tty`. Mirrors the shell snippet at `mlflow.toml [actions.copy-id]:131` but in Python (`subprocess.run([...], input=ident, text=True, check=False)`), eliminating shell-quoting risk.
- Stderr confirmation: `[mlf] copied: <first 12 chars>…`.

#### `mlf plot <run_id> [metric...]`
- `tyro` dataclass: `run_id: str`, `metrics: list[str] = []`, `width: int | None = None`, `height: int = 20`, `theme: str = "pro"`.
- `client.get_run(run_id)` → fail with a helpful message if run lacks metrics.
- For each requested key (or all keys if none specified): `client.get_metric_history(run_id, key)` → list of `Metric(value, timestamp, step)` objects.
- plotext: `plt.theme(theme)`, `plt.title(f"{run_id[:8]} — {run.info.run_name or 'unnamed'}")`, one `plt.plot(steps, values, label=key)` per metric.
- `--width`/`--height` map to `plt.plot_size(w, h)`; default → terminal-fit (omit the call).
- For single-metric mode, also print a stats line under the plot: `min=… max=… last=… n=…`.

#### `mlf list experiments|runs|models`
- `tyro` dataclass with positional `kind: Literal["experiments", "runs", "models"]`.
- Columns mirror the tv channel display layout for consistency (id, status, name, lifecycle, last_update). Status only for runs.
- `--limit` default 50. For runs without `--experiment`, lists recent across all experiments via the same `search_runs` call pattern as `executable_mlflow-source.py:122-131`.
- `--json` dumps `list[dict]` (using `dataclasses.asdict` on a small `Row` dataclass) to stdout for piping.
- Default output: `rich.table.Table`.

#### `mlf download <model_name>[@<alias|version>]`
- Parse `model_name@version` or `model_name@alias` or bare `model_name` (defaults to `@latest`).
- Resolve to a `ModelVersion`:
  - Numeric version → `client.get_model_version(name, version)`.
  - Alias → `client.get_model_version_by_alias(name, alias)`.
  - `latest` → `sorted(client.search_model_versions(f"name='{name}'"), key=lambda v: v.creation_timestamp, reverse=True)[0]`.
- Destination: `--dest DIR` or auto: `./<model_name>-<version>/` resolved against cwd.
- `mlflow.artifacts.download_artifacts(artifact_uri=mv.source, dst_path=str(dest))`.
- Print absolute resolved path + total size (recursive `os.walk` + `stat().st_size`). One-line hint on stderr about `mlflow models serve -m <path>` for HTTP serving, so stdout stays clean for piping.

### Channel TOML change

In `dot_config/television/cable/mlflow.toml`, two diffs:

1. `[keybindings]` block (around line 98), add:
   ```toml
   ctrl-b = "actions:open-browser"
   ```
2. The keybinding table inside the top-comment header (around line 36-49), add a row:
   ```
   #   Ctrl+B     Same as Ctrl+O — "B for browser" muscle-memory alias
   ```

No action body changes. Both keys trigger the same existing `[actions.open-browser]` shell snippet (already handles HTTP-URI guard + URL building + cross-platform opener). Reusing the action keeps the channel self-contained — `tv mlflow` works even if `mlf` isn't installed yet.

### justfile recipe

Add near `justfile:468` (after the `fleet *ARGS:` block):
```makefile
# MLflow CLI umbrella — wraps tv mlflow + plot/open/copy/download helpers.
# See dot_dotfiles/bin/executable_mlf for the dispatch surface.
mlf *ARGS:
    @uv run --script ./dot_dotfiles/bin/executable_mlf {{ARGS}}
```

### Reuse from existing codebase

- `_source_path()` from `dot_dotfiles/bin/executable_fleet:67-89` — copy verbatim, s/fleet/mlf/.
- `USAGE` / dispatch-dict structure from `executable_fleet:36-64, 186-213`.
- `detect_kind()` logic from `dot_config/television/executable_mlflow-preview.py:42-60` (`RUN_ID_RE`, `_detect_kind`).
- `_ms_to_iso()` from `dot_config/television/executable_mlflow-source.py:70-77`.
- Tyro `@dataclass` + `tyro.cli()` pattern from `scripts/fleet/info.py:29-40`.
- HTTP-URI guard + URL builder skeleton from `mlflow.toml [actions.open-browser]:142` — re-implement in Python (no shell quoting).

### Files NOT touched (and why)

- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — `tyro`, `rich`, `plotext` are PEP 723 inline deps (matches `executable_fleet`, `executable_sms`, `executable_mi-router` convention). Only `mlflow` is ansible-pinned (already there).
- `dot_config/television/cable/mlflow.toml [actions.open-browser]` body — left as the inline shell snippet for self-containment. A future refactor could replace it with `mlf open '{split:\t:0}'`, but that couples the channel to the umbrella; revisit after `mlf` stabilizes.
- `docs/shells/aliases.md` — `mlf` is a `$PATH` binary, not a shell alias.
- `CLAUDE.md` keybindings table — `Ctrl+B` is scoped to the tv channel namespace (not shell / tmux root); no shadowing concern.
- `CLAUDE.md` cross-file maintenance table — defer until `docs/this_repo/mlf-cli.md` exists. Adding a maintenance row without a doc surface is premature.

## Verification

1. **Syntax** — `python -c "import ast; ast.parse(open('dot_dotfiles/bin/executable_mlf').read().split(chr(10),1)[1])"`. Repeat for each `scripts/mlf/*.py`.
2. **Help paths** — `mlf -h`, `mlf help`, `mlf` (no args), `mlf <sub> -h`, `mlf unknownsub` (expect exit 2 with USAGE).
3. **tv passthrough** —
   ```
   MLFLOW_TRACKING_URI=http://192.168.222.207:15002 mlf tv
   ```
   Same picker as `tv mlflow`. Argv passthrough: `mlf tv --source-command "~/.config/television/mlflow-source.py runs-recent"` opens the source-overridden view.
4. **Open** —
   ```
   MLFLOW_TRACKING_URI=http://192.168.222.207:15002 mlf open 1
   MLFLOW_TRACKING_URI=http://192.168.222.207:15002 mlf open cb250b888c5b41e98960b01360e4f41d
   MLFLOW_TRACKING_URI=http://192.168.222.207:15002 mlf open SomeRegisteredModel
   ```
   Expect: `/#/experiments/1`, `/#/experiments/1/runs/cb250b…`, `/#/models/SomeRegisteredModel`.
5. **Open guard** —
   ```
   MLFLOW_TRACKING_URI=sqlite:///$PWD/mlflow.db mlf open 1
   ```
   Expect stderr message + exit 1, no browser launched.
6. **Copy** — `mlf copy abc123` then paste into another app. On macOS uses pbcopy; on Linux X11 uses xclip; over SSH falls back to OSC52 (verify via `ssh -t <host> "mlf copy hello"`).
7. **Plot all metrics** —
   ```
   MLFLOW_TRACKING_URI=http://192.168.222.207:15002 mlf plot cb250b888c5b41e98960b01360e4f41d
   ```
   Expect plotext chart in terminal; multiple traces if the run logged multiple keys.
8. **Plot one metric** — append a metric name; verify only that key is plotted and the stats line appears.
9. **List** —
   ```
   mlf list experiments --limit 5
   mlf list runs --limit 10 --experiment 1
   mlf list models --json | jq '.[0]'
   ```
   Expect rich tables (default) and parseable JSON (`--json`).
10. **Download** —
    ```
    mlf download MyModel@1 --dest /tmp/mymodel
    ```
    Expect artifacts under `/tmp/mymodel/`; stderr hints `mlflow models serve` command.
11. **Ctrl+B in `tv mlflow`** — launch `tv mlflow`, highlight an experiment row, press `Ctrl+B`. Browser opens to `/#/experiments/<id>`. Same behavior as `Ctrl+O`.
12. **`just mlf …`** — recipe exists; `just mlf list experiments --limit 1` works.
13. **App-level validation** (per CLAUDE.md "Validate app configs with the app, not just syntax" invariant) — `tv` re-parses `mlflow.toml` cleanly after the Ctrl+B addition: `tv --list-channels | grep mlflow` and `tv mlflow --help` exit 0.
