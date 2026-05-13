#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mlflow>=3.4"]
# ///
"""Preview emitter for the `mlflow` tv channel.

Usage:
    mlflow-preview.py auto <id> [--view full|metrics]

The `auto` kind inspects the id shape and routes to the right entity:
    - 32-hex-char id  -> run
    - all-digit id    -> experiment
    - anything else   -> registered model name

Output is human-readable JSON-ish. Uses rich's syntax highlighting when
present (mlflow itself depends on rich, so within the uv venv created by
the PEP 723 shebang above, rich is always available).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import warnings
from datetime import datetime, timezone

os.environ.setdefault("PYTHONWARNINGS", "ignore")
os.environ.setdefault("MLFLOW_HTTP_REQUEST_TIMEOUT", "5")
os.environ.setdefault("MLFLOW_HTTP_REQUEST_MAX_RETRIES", "1")
warnings.filterwarnings("ignore")

import logging  # noqa: E402
import mlflow  # noqa: E402
from mlflow.tracking import MlflowClient  # noqa: E402

logging.getLogger("mlflow").setLevel(logging.WARNING)
logging.getLogger("alembic").setLevel(logging.WARNING)

RUN_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def _ms_to_iso(ms: int | None) -> str:
    if not ms:
        return "-"
    try:
        dt = datetime.fromtimestamp(int(ms) / 1000, tz=timezone.utc).astimezone()
        return dt.strftime("%Y-%m-%d %H:%M:%S %z")
    except (OverflowError, OSError, ValueError):
        return "-"


def _detect_kind(ident: str) -> str:
    if RUN_ID_RE.match(ident):
        return "run"
    if ident.isdigit():
        return "experiment"
    return "model"


def _emit(payload: dict | str) -> None:
    # Plain output — coloring is the channel TOML's job (it pipes us through
    # `bat -l json` / `bat -l yaml`). Rich's force_terminal=True did not emit
    # ANSI through TV's preview pipe in practice, and piping through bat is
    # what super-productivity.toml does (via `jq -C`) for the same reason.
    if isinstance(payload, str):
        print(payload)
    else:
        print(json.dumps(payload, indent=2, default=str))


def _run_full(client: MlflowClient, run_id: str) -> dict:
    r = client.get_run(run_id)
    info = r.info
    data = r.data
    return {
        "run_id": info.run_id,
        "run_name": info.run_name,
        "experiment_id": info.experiment_id,
        "status": info.status,
        "start_time": _ms_to_iso(info.start_time),
        "end_time": _ms_to_iso(info.end_time),
        "user_id": info.user_id,
        "artifact_uri": info.artifact_uri,
        "lifecycle_stage": info.lifecycle_stage,
        "params": dict(data.params or {}),
        "metrics": dict(data.metrics or {}),
        "tags": {k: v for k, v in (data.tags or {}).items() if not k.startswith("mlflow.")},
        "mlflow_tags": {k: v for k, v in (data.tags or {}).items() if k.startswith("mlflow.")},
    }


def _run_metrics(client: MlflowClient, run_id: str) -> dict:
    r = client.get_run(run_id)
    metrics = dict(r.data.metrics or {})
    return {
        "run_id": run_id,
        "status": r.info.status,
        "metrics": {k: metrics[k] for k in sorted(metrics)} if metrics else {},
    }


def _experiment_full(client: MlflowClient, exp_id: str) -> dict:
    e = client.get_experiment(exp_id)
    recent = client.search_runs(
        experiment_ids=[exp_id],
        max_results=5,
        order_by=["attributes.start_time DESC"],
    )
    return {
        "experiment_id": e.experiment_id,
        "name": e.name,
        "lifecycle_stage": e.lifecycle_stage,
        "artifact_location": e.artifact_location,
        "creation_time": _ms_to_iso(e.creation_time),
        "last_update_time": _ms_to_iso(e.last_update_time),
        "tags": dict(e.tags or {}),
        "recent_runs": [
            {
                "run_id": r.info.run_id,
                "run_name": r.info.run_name,
                "status": r.info.status,
                "start_time": _ms_to_iso(r.info.start_time),
            }
            for r in recent
        ],
    }


def _experiment_metrics(client: MlflowClient, exp_id: str) -> dict:
    e = client.get_experiment(exp_id)
    runs = client.search_runs(
        experiment_ids=[exp_id],
        max_results=20,
        order_by=["attributes.start_time DESC"],
    )
    # Aggregate latest metric value per key, taken from the most recent run
    # that logged it. Keeps the source run id alongside so the user can
    # spot-check provenance without leaving the preview pane.
    seen: dict[str, tuple[str, float]] = {}
    for r in runs:
        for k, v in (r.data.metrics or {}).items():
            if k not in seen:
                seen[k] = (r.info.run_id, v)
    return {
        "experiment": e.name,
        "experiment_id": e.experiment_id,
        "runs_scanned": len(runs),
        "metrics": {k: {"value": seen[k][1], "from_run": seen[k][0][:8]} for k in sorted(seen)},
    }


def _model_full(client: MlflowClient, name: str) -> dict:
    m = client.get_registered_model(name)
    return {
        "name": m.name,
        "description": m.description,
        "creation_timestamp": _ms_to_iso(m.creation_timestamp),
        "last_updated_timestamp": _ms_to_iso(m.last_updated_timestamp),
        "tags": dict(m.tags or {}),
        "latest_versions": [
            {
                "version": v.version,
                "stage": v.current_stage,
                "status": v.status,
                "run_id": v.run_id,
                "source": v.source,
                "creation_timestamp": _ms_to_iso(v.creation_timestamp),
            }
            for v in (m.latest_versions or [])
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("kind", choices=["auto", "run", "experiment", "model"])
    ap.add_argument("id")
    ap.add_argument("--view", choices=["full", "metrics"], default="full")
    args = ap.parse_args()

    ident = args.id.strip()
    # `__hint__` is the source-side sentinel for unreachable / empty / unscoped
    # rows. Real ids never use that string (run ids are 32-hex; experiment ids
    # are non-negative integers including 0; model names are arbitrary but
    # can't legally contain `__hint__`). Keep in sync with mlflow-source.py.
    if not ident or ident == "__hint__":
        # JSON-shaped so the TOML's `bat -l json` pipe still colorizes it.
        _emit(
            {
                "help": "MLflow TV channel",
                "current_tracking_uri": mlflow.get_tracking_uri() or "(unset)",
                "set_backend": [
                    "MLFLOW_TRACKING_URI=http://host:port tv mlflow",
                    "MLFLOW_TRACKING_URI=sqlite:///$PWD/mlflow.db tv mlflow",
                    "MLFLOW_TRACKING_URI=file:./mlruns tv mlflow",
                ],
                "shortcuts": {
                    "Ctrl+S": "cycle source (experiments / runs-recent / runs-experiment / models)",
                    "Ctrl+F": "cycle preview (full JSON / metrics summary)",
                    "Enter":  "drill into experiment runs (or open detail for run/model rows)",
                    "Alt+R":  "explicit drill on experiment row",
                    "Ctrl+Y": "copy id to clipboard",
                    "Ctrl+O": "open in browser (HTTP backends only)",
                    "Alt+J":  "dump full JSON in pager",
                },
            }
        )
        return 0

    kind = args.kind if args.kind != "auto" else _detect_kind(ident)
    client = MlflowClient()

    try:
        if kind == "run":
            payload = _run_full(client, ident) if args.view == "full" else _run_metrics(client, ident)
        elif kind == "experiment":
            payload = (
                _experiment_full(client, ident)
                if args.view == "full"
                else _experiment_metrics(client, ident)
            )
        elif kind == "model":
            # Models don't have a meaningful "metrics" view — fall back to full.
            payload = _model_full(client, ident)
        else:
            payload = f"# unknown kind: {kind}"
    except Exception as e:  # noqa: BLE001
        uri = mlflow.get_tracking_uri() or "(unset)"
        print(
            f"# preview failed for {kind} id={ident}\n"
            f"# tracking_uri: {uri}\n"
            f"# {type(e).__name__}: {str(e).splitlines()[0][:200]}"
        )
        return 0

    _emit(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
