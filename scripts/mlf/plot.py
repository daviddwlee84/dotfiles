"""mlf plot — terminal line plot of a run's metric history.

Pulls `client.get_metric_history(run_id, key)` for each requested metric
key (or every key the run logged when none specified) and renders one
plotext chart with one trace per metric.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from typing import Annotated

import plotext as plt
import tyro

from scripts.mlf import make_client, tracking_uri


@dataclass
class Args:
    run_id: Annotated[
        str,
        tyro.conf.Positional,
        tyro.conf.arg(help="MLflow run_id (32-char hex)"),
    ]
    metrics: Annotated[
        list[str],
        tyro.conf.Positional,
        tyro.conf.arg(
            help=(
                "Metric keys to plot. Empty (default) plots every key the run logged."
            ),
        ),
    ] = field(default_factory=list)
    width: Annotated[
        int | None,
        tyro.conf.arg(help="Plot width in cells. Default: terminal width."),
    ] = None
    height: Annotated[
        int,
        tyro.conf.arg(help="Plot height in cells."),
    ] = 20
    theme: Annotated[
        str,
        tyro.conf.arg(help="plotext theme name (pro, clear, dark, matrix, …)"),
    ] = "pro"


def _summary_line(values: list[float]) -> str:
    return f"  min={min(values):.4g}  max={max(values):.4g}  last={values[-1]:.4g}  n={len(values)}"


def cli(args: Args) -> int:
    client = make_client()
    try:
        run = client.get_run(args.run_id)
    except Exception as e:  # noqa: BLE001
        print(
            f"mlf plot: cannot load run '{args.run_id}'\n"
            f"  tracking_uri: {tracking_uri()}\n"
            f"  {type(e).__name__}: {str(e).splitlines()[0][:200]}",
            file=sys.stderr,
        )
        return 1

    available = list((run.data.metrics or {}).keys())
    if not available:
        print(
            f"mlf plot: run {args.run_id[:8]} has no metrics logged.",
            file=sys.stderr,
        )
        return 1

    keys = args.metrics or available
    missing = [k for k in args.metrics if k not in available]
    if missing:
        print(
            f"mlf plot: unknown metric(s): {', '.join(missing)}\n"
            f"  available: {', '.join(available)}",
            file=sys.stderr,
        )
        return 1

    series: dict[str, tuple[list[int], list[float]]] = {}
    skipped: list[tuple[str, str]] = []
    for key in keys:
        try:
            history = client.get_metric_history(args.run_id, key)
        except Exception as e:  # noqa: BLE001
            # One slow key (commonly a system.* metric over a slow link)
            # shouldn't abort the whole plot. We surface the failure in a
            # post-plot warning so user-relevant training metrics still
            # render. Bump MLFLOW_HTTP_REQUEST_TIMEOUT for the whole CLI
            # invocation if too many keys fall into this branch.
            skipped.append((key, f"{type(e).__name__}: {str(e).splitlines()[0][:80]}"))
            continue
        if not history:
            continue
        # mlflow returns Metric(value, timestamp, step). Sort by step for a
        # well-defined x-axis even when step ordering wasn't guaranteed at
        # logging time.
        sorted_hist = sorted(history, key=lambda m: m.step)
        steps = [m.step for m in sorted_hist]
        values = [m.value for m in sorted_hist]
        series[key] = (steps, values)

    if not series:
        print(
            f"mlf plot: no metric history available for run {args.run_id[:8]}.",
            file=sys.stderr,
        )
        if skipped:
            print(
                f"  all {len(skipped)} keys failed to fetch — first: {skipped[0][0]} ({skipped[0][1]}).\n"
                "  Try `export MLFLOW_HTTP_REQUEST_TIMEOUT=30` for slow backends, "
                "or pass explicit metric names: `mlf plot <run_id> loss accuracy`.",
                file=sys.stderr,
            )
        return 1

    plt.clf()
    plt.theme(args.theme)
    if args.width is not None:
        plt.plot_size(args.width, args.height)
    else:
        # plot_size needs both dims — read the current terminal width.
        plt.plotsize(plt.terminal_width(), args.height)

    title = f"{args.run_id[:8]} — {run.info.run_name or 'unnamed'}"
    plt.title(title)
    plt.xlabel("step")
    plt.ylabel("value")
    for key, (steps, values) in series.items():
        plt.plot(steps, values, label=key)
    plt.show()

    if len(series) == 1:
        only_key = next(iter(series))
        _, only_values = series[only_key]
        print(f"\n{only_key}:{_summary_line(only_values)}")
    else:
        print()
        for key, (_, values) in series.items():
            print(f"{key}:{_summary_line(values)}")

    if skipped:
        print(
            f"\n[mlf plot] skipped {len(skipped)} metric(s) (e.g. {skipped[0][0]}: {skipped[0][1]}).\n"
            "  Bump MLFLOW_HTTP_REQUEST_TIMEOUT or pass explicit keys to silence.",
            file=sys.stderr,
        )
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="mlf plot"))


if __name__ == "__main__":
    sys.exit(main())
