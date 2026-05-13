"""mlf list — tabular listing of experiments / runs / registered models.

Default output is a rich.Table for terminal browsing. `--json` emits a
parseable list-of-dicts for piping through jq.

Designed for one-shot scripted use; the interactive picker is `tv mlflow`.
"""
from __future__ import annotations

import dataclasses
import json
import sys
from dataclasses import dataclass
from typing import Annotated, Literal

import tyro
from rich.console import Console
from rich.table import Table

from scripts.mlf import make_client, ms_to_iso, tracking_uri

STATUS_ICON = {
    "RUNNING": "▶ running",
    "FINISHED": "✓ done",
    "FAILED": "✗ failed",
    "KILLED": "■ killed",
    "SCHEDULED": "○ scheduled",
}


@dataclass
class Args:
    kind: Annotated[
        Literal["experiments", "runs", "models"],
        tyro.conf.Positional,
        tyro.conf.arg(help="Entity kind to list."),
    ]
    limit: Annotated[
        int, tyro.conf.arg(help="Maximum rows to fetch.")
    ] = 50
    experiment: Annotated[
        str | None,
        tyro.conf.arg(
            help=(
                "Restrict `runs` listing to one experiment_id. "
                "Ignored for experiments/models."
            ),
        ),
    ] = None
    json_out: Annotated[
        bool,
        tyro.conf.arg(
            name="json",
            help="Emit JSON to stdout instead of a rich table.",
        ),
    ] = False


@dataclass
class Row:
    id: str
    kind: str
    name: str
    status: str
    lifecycle: str
    extra: str
    last_update: str


def _experiments(client, limit: int) -> list[Row]:
    rows = []
    for e in client.search_experiments(max_results=limit):
        rows.append(
            Row(
                id=str(e.experiment_id),
                kind="experiment",
                name=e.name or "(unnamed)",
                status="-",
                lifecycle=e.lifecycle_stage or "-",
                extra=e.artifact_location or "",
                last_update=ms_to_iso(e.last_update_time),
            )
        )
    return rows


def _runs(client, limit: int, exp_id: str | None) -> list[Row]:
    if exp_id:
        try:
            exp = client.get_experiment(exp_id)
        except Exception as e:  # noqa: BLE001
            print(
                f"mlf list: experiment_id={exp_id} not found — {str(e)[:80]}",
                file=sys.stderr,
            )
            return []
        exp_ids = [exp.experiment_id]
        name_by_id = {exp.experiment_id: (exp.name or "(unnamed)")}
    else:
        exps = list(client.search_experiments(max_results=200))
        if not exps:
            return []
        exp_ids = [e.experiment_id for e in exps]
        name_by_id = {e.experiment_id: (e.name or "(unnamed)") for e in exps}
    runs = client.search_runs(
        experiment_ids=exp_ids,
        max_results=limit,
        order_by=["attributes.start_time DESC"],
    )
    rows = []
    for r in runs:
        info = r.info
        rows.append(
            Row(
                id=info.run_id,
                kind="run",
                name=info.run_name or info.run_id[:8],
                status=STATUS_ICON.get(info.status, info.status or "?"),
                lifecycle=info.lifecycle_stage or "-",
                extra=name_by_id.get(info.experiment_id, info.experiment_id),
                last_update=ms_to_iso(info.start_time),
            )
        )
    return rows


def _models(client, limit: int) -> list[Row]:
    try:
        models = list(client.search_registered_models(max_results=limit))
    except Exception as e:  # noqa: BLE001
        # The file: backend has no registry — surface a friendly hint
        # instead of a raw traceback.
        print(
            f"mlf list models: registry unavailable — {str(e)[:200]}\n"
            f"  tracking_uri: {tracking_uri()}",
            file=sys.stderr,
        )
        return []
    rows = []
    for m in models:
        stages = sorted({v.current_stage for v in (m.latest_versions or []) if v.current_stage})
        stage_label = ",".join(stages) if stages else "-"
        rows.append(
            Row(
                id=m.name,
                kind="model",
                name=m.name,
                status=stage_label,
                lifecycle="-",
                extra=(m.description or "").splitlines()[0] if m.description else "",
                last_update=ms_to_iso(m.last_updated_timestamp),
            )
        )
    return rows


_COLUMNS_BY_KIND = {
    "experiments": [("id", "id"), ("lifecycle", "lifecycle"), ("name", "name"), ("last_update", "last_update")],
    "runs": [
        ("id", "run_id"),
        ("status", "status"),
        ("extra", "experiment"),
        ("name", "run_name"),
        ("last_update", "start_time"),
    ],
    "models": [
        ("id", "name"),
        ("status", "stages"),
        ("extra", "description"),
        ("last_update", "last_update"),
    ],
}


def _render_table(kind: str, rows: list[Row]) -> None:
    table = Table(show_lines=False, header_style="bold")
    cols = _COLUMNS_BY_KIND[kind]
    for _, header in cols:
        table.add_column(header)
    for row in rows:
        table.add_row(*[getattr(row, attr) for attr, _ in cols])
    Console().print(table)


def cli(args: Args) -> int:
    client = make_client()
    if args.kind == "experiments":
        rows = _experiments(client, args.limit)
    elif args.kind == "runs":
        rows = _runs(client, args.limit, args.experiment)
    else:
        rows = _models(client, args.limit)

    if args.json_out:
        print(json.dumps([dataclasses.asdict(r) for r in rows], indent=2, default=str))
        return 0

    if not rows:
        print(f"mlf list {args.kind}: (no rows)", file=sys.stderr)
        return 0

    _render_table(args.kind, rows)
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="mlf list"))


if __name__ == "__main__":
    sys.exit(main())
