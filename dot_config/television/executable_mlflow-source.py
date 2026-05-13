#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mlflow>=3.4"]
# ///
"""Source emitter for the `mlflow` tv channel.

Usage:
    mlflow-source.py <experiments|runs-recent|runs-experiment|models>

Emits TSV rows. Column 0 is always the id that TV passes to the preview
command (experiment_id / run_id / model_name). Column 1 is an emoji or
status marker; remaining columns are display-only.

Backend resolution honours `MLFLOW_TRACKING_URI` (env var). When unset,
mlflow falls back to `file:./mlruns` in the current directory.

On any unreachable / unconfigured backend, a single hint row with id `0`
is emitted instead of crashing — preserves the same UX as the
super-productivity channel.
"""
from __future__ import annotations

import os
import sys
import warnings
from datetime import datetime, timezone
from typing import Iterable

os.environ.setdefault("PYTHONWARNINGS", "ignore")
# Fail fast on unreachable HTTP tracking servers: stale DNS or a typo'd
# MLFLOW_TRACKING_URI would otherwise hang TV for ~60s before the exception
# handler emits the hint row (mlflow defaults are 120s / 5 retries).
os.environ.setdefault("MLFLOW_HTTP_REQUEST_TIMEOUT", "5")
os.environ.setdefault("MLFLOW_HTTP_REQUEST_MAX_RETRIES", "1")
warnings.filterwarnings("ignore")

import logging  # noqa: E402
import mlflow  # noqa: E402
from mlflow.tracking import MlflowClient  # noqa: E402

# Silence mlflow's own INFO logging (e.g. "Creating initial MLflow database
# tables..." when sqlite is auto-bootstrapped). MUST run AFTER `import
# mlflow`: mlflow.utils.logging_utils installs its handlers at import time
# and pre-import setLevel calls get overwritten.
logging.getLogger("mlflow").setLevel(logging.WARNING)
logging.getLogger("alembic").setLevel(logging.WARNING)

MAX_EXPERIMENTS = 200
MAX_RUNS = 50

STATUS_ICON = {
    "RUNNING": "▶ running",
    "FINISHED": "✓ done",
    "FAILED": "✗ failed",
    "KILLED": "■ killed",
    "SCHEDULED": "○ scheduled",
}


def _clean(value: object) -> str:
    s = "" if value is None else str(value)
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")


def tsv(*cols: object) -> None:
    print("\t".join(_clean(c) for c in cols))


def _ms_to_iso(ms: int | None) -> str:
    if not ms:
        return "-"
    try:
        dt = datetime.fromtimestamp(int(ms) / 1000, tz=timezone.utc).astimezone()
        return dt.strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return "-"


def _hint(reason: str, detail: str) -> None:
    # Sentinel id `__hint__` MUST NOT collide with real mlflow ids — mlflow's
    # default backend assigns experiment_id `0` to the auto-created Default
    # experiment, so "0" would shadow a real row. Keep this in sync with the
    # preview script's special-case branch.
    uri = mlflow.get_tracking_uri() or "(unset)"
    tsv("__hint__", f"⚠ {reason}", uri[:48], detail)


def _list_experiments(client: MlflowClient) -> list:
    return list(client.search_experiments(max_results=MAX_EXPERIMENTS))


def cmd_experiments(client: MlflowClient) -> None:
    exps = _list_experiments(client)
    if not exps:
        tsv("__hint__", "ℹ empty", mlflow.get_tracking_uri()[:48], "No experiments — log a run to see it here")
        return
    for e in exps:
        tsv(
            e.experiment_id,
            "📊",
            e.lifecycle_stage or "-",
            e.name or "(unnamed)",
            _ms_to_iso(e.last_update_time),
        )


def _emit_runs(runs: Iterable, exp_name_by_id: dict[str, str]) -> int:
    count = 0
    for r in runs:
        info = r.info
        rid = info.run_id
        status = STATUS_ICON.get(info.status, info.status or "?")
        exp_name = exp_name_by_id.get(info.experiment_id, info.experiment_id)
        name = info.run_name or rid[:8]
        tsv(rid, status, exp_name, name, _ms_to_iso(info.start_time))
        count += 1
    return count


def cmd_runs_recent(client: MlflowClient) -> None:
    exps = _list_experiments(client)
    if not exps:
        tsv("__hint__", "ℹ empty", mlflow.get_tracking_uri()[:48], "No experiments — log a run to see it here")
        return
    name_by_id = {e.experiment_id: (e.name or "(unnamed)") for e in exps}
    runs = client.search_runs(
        experiment_ids=list(name_by_id.keys()),
        max_results=MAX_RUNS,
        order_by=["attributes.start_time DESC"],
    )
    if _emit_runs(runs, name_by_id) == 0:
        tsv("__hint__", "ℹ empty", mlflow.get_tracking_uri()[:48], "No runs yet — start a run to see it here")


def cmd_runs_experiment(client: MlflowClient) -> None:
    exp_id = os.environ.get("MLFLOW_EXPERIMENT_ID", "").strip()
    if not exp_id:
        tsv(
            "__hint__",
            "ℹ unscoped",
            "MLFLOW_EXPERIMENT_ID",
            "Press Alt+R on an experiment row, or export MLFLOW_EXPERIMENT_ID=<id> and Ctrl+R",
        )
        return
    try:
        exp = client.get_experiment(exp_id)
    except Exception as e:  # noqa: BLE001
        _hint("not found", f"experiment_id={exp_id} — {str(e)[:80]}")
        return
    name_by_id = {exp.experiment_id: (exp.name or "(unnamed)")}
    runs = client.search_runs(
        experiment_ids=[exp.experiment_id],
        max_results=MAX_RUNS,
        order_by=["attributes.start_time DESC"],
    )
    if _emit_runs(runs, name_by_id) == 0:
        tsv("__hint__", "ℹ empty", f"exp {exp.experiment_id}", f"No runs in '{exp.name}'")


def cmd_models(client: MlflowClient) -> None:
    try:
        models = list(client.search_registered_models(max_results=200))
    except Exception as e:  # noqa: BLE001
        # Model registry isn't supported by file: backend at all.
        _hint("no registry", str(e)[:80])
        return
    if not models:
        tsv("__hint__", "ℹ empty", mlflow.get_tracking_uri()[:48], "No registered models")
        return
    for m in models:
        stages = sorted({v.current_stage for v in (m.latest_versions or []) if v.current_stage})
        stage_label = ",".join(stages) if stages else "-"
        desc = (m.description or "").splitlines()[0] if m.description else ""
        tsv(
            m.name,
            "📦",
            stage_label,
            desc or "(no description)",
            _ms_to_iso(m.last_updated_timestamp),
        )


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {
        "experiments",
        "runs-recent",
        "runs-experiment",
        "models",
    }:
        print(
            "usage: mlflow-source.py <experiments|runs-recent|runs-experiment|models>",
            file=sys.stderr,
        )
        return 2

    mode = sys.argv[1]
    client = MlflowClient()

    # Preflight: any list call against the configured backend. Catches both
    # unreachable HTTP servers and unreadable file/sqlite paths.
    try:
        client.search_experiments(max_results=1)
    except Exception as e:  # noqa: BLE001
        _hint("unreachable", str(e).splitlines()[0][:100])
        return 0

    if mode == "experiments":
        cmd_experiments(client)
    elif mode == "runs-recent":
        cmd_runs_recent(client)
    elif mode == "runs-experiment":
        cmd_runs_experiment(client)
    elif mode == "models":
        cmd_models(client)
    return 0


if __name__ == "__main__":
    sys.exit(main())
