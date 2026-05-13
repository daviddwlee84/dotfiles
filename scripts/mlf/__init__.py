"""mlf — shared helpers for the MLflow umbrella CLI.

The umbrella binary (`dot_dotfiles/bin/executable_mlf`) plus subcommand
modules (`scripts/mlf/plot.py`, `list.py`, `download.py`) all share this
namespace. Helpers live here instead of being duplicated per-module.

`MlflowClient` is constructed lazily (on first call) — importing mlflow is
~1s warm, so subcommands that don't need a client (e.g. `mlf -h`,
`mlf tv`) don't pay the cost.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import warnings
from datetime import datetime, timezone
from typing import TYPE_CHECKING

# Fail fast on unreachable HTTP backends. Matches the env defaults used by
# the tv-channel helpers (executable_mlflow-source.py / executable_mlflow-
# preview.py) so a typo'd MLFLOW_TRACKING_URI surfaces in seconds, not
# minutes. mlflow defaults are 120s timeout × 5 retries.
os.environ.setdefault("PYTHONWARNINGS", "ignore")
os.environ.setdefault("MLFLOW_HTTP_REQUEST_TIMEOUT", "5")
os.environ.setdefault("MLFLOW_HTTP_REQUEST_MAX_RETRIES", "1")
warnings.filterwarnings("ignore")

if TYPE_CHECKING:
    from mlflow.tracking import MlflowClient

# 32-char lowercase hex = mlflow run_id. Anchored — partial hex strings
# (e.g. an 8-char short id from a copy-paste) don't match.
RUN_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def make_client() -> "MlflowClient":
    """Build a MlflowClient. Imports lazily; silences mlflow's INFO logs.

    `logging.getLogger("mlflow").setLevel(WARNING)` MUST run AFTER
    `import mlflow` — mlflow.utils.logging_utils installs handlers at
    import time and pre-import setLevel calls get overwritten.
    """
    import logging

    # `from mlflow.tracking import MlflowClient` loads the top-level mlflow
    # package as a side-effect, which is when mlflow.utils.logging_utils
    # installs its INFO-level handlers. The setLevel call below MUST run
    # after that, not before — pre-import setLevel gets overwritten.
    from mlflow.tracking import MlflowClient

    logging.getLogger("mlflow").setLevel(logging.WARNING)
    logging.getLogger("alembic").setLevel(logging.WARNING)
    return MlflowClient()


def detect_kind(ident: str) -> str:
    """Classify a row identifier from the tv channel layout.

    Returns one of: "run" | "experiment" | "model".

      32-hex     -> run        (RUN_ID_RE)
      digits-only-> experiment (mlflow assigns non-negative ints)
      else       -> model      (registered model name; arbitrary string)

    Kept in sync with dot_config/television/executable_mlflow-preview.py:_detect_kind.
    """
    if RUN_ID_RE.match(ident):
        return "run"
    if ident.isdigit():
        return "experiment"
    return "model"


def ms_to_iso(ms: int | None) -> str:
    """Convert mlflow's millisecond timestamps to local ISO strings.

    Returns "-" on missing/invalid input so table renderers can use the
    output directly without further None-checks.
    """
    if not ms:
        return "-"
    try:
        dt = datetime.fromtimestamp(int(ms) / 1000, tz=timezone.utc).astimezone()
        return dt.strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return "-"


def tracking_uri() -> str:
    """Current MLFLOW_TRACKING_URI (resolved). Returns "(unset)" if absent."""
    import mlflow

    return mlflow.get_tracking_uri() or "(unset)"


def tracking_uri_is_http() -> bool:
    """True when the configured tracking URI uses http(s):// — the only
    backend with a web UI that `mlf open` can deep-link into."""
    uri = tracking_uri()
    return uri.startswith("http://") or uri.startswith("https://")


def open_id(ident: str) -> int:
    """Open the MLflow web UI deep-link for `ident`. Returns exit code.

    Pure helper — no argv parsing. Used by:
      - `mlf open <id>` (via _dispatch_open shim in executable_mlf)
      - `mlf` TUI's `b` keybinding (in-process call, no subprocess)
    """
    uri = tracking_uri()
    if not tracking_uri_is_http():
        print(
            f"mlf open: tracking URI is not http(s):// — current: {uri}\n"
            "  Set MLFLOW_TRACKING_URI=http(s)://host:port to use the MLflow web UI.",
            file=sys.stderr,
        )
        return 1

    base = uri.rstrip("/")
    kind = detect_kind(ident)
    if kind == "run":
        client = make_client()
        try:
            run = client.get_run(ident)
            exp_id = run.info.experiment_id
        except Exception as e:  # noqa: BLE001
            print(
                f"mlf open: cannot resolve run '{ident}' — "
                f"{type(e).__name__}: {str(e).splitlines()[0][:200]}",
                file=sys.stderr,
            )
            return 1
        url = f"{base}/#/experiments/{exp_id}/runs/{ident}"
    elif kind == "experiment":
        url = f"{base}/#/experiments/{ident}"
    else:
        url = f"{base}/#/models/{ident}"

    import webbrowser

    print(f"[mlf] open: {url}", file=sys.stderr)
    opened = webbrowser.open(url)
    if not opened:
        print(
            "mlf open: no usable browser opener found (open/xdg-open/wslview missing).\n"
            f"  URL: {url}",
            file=sys.stderr,
        )
        return 1
    return 0


def copy_id(payload: str) -> int:
    """Copy `payload` to the clipboard. Returns exit code.

    Provider chain: pbcopy → wl-copy → xclip → OSC 52 fallback to /dev/tty.
    Mirrors the shell snippet in mlflow.toml [actions.copy-id]. Pure helper
    so the TUI's `y` action can reuse it without spawning a subprocess.
    """
    providers = [
        ["pbcopy"],
        ["wl-copy"],
        ["xclip", "-selection", "clipboard"],
    ]
    for cmd in providers:
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=payload, text=True, check=True)
            except subprocess.CalledProcessError as e:
                print(
                    f"mlf copy: {cmd[0]} failed ({e.returncode}); falling through",
                    file=sys.stderr,
                )
                continue
            print(
                f"[mlf] copied via {cmd[0]}: {payload[:12]}{'…' if len(payload) > 12 else ''}",
                file=sys.stderr,
            )
            return 0

    try:
        import base64

        b64 = base64.b64encode(payload.encode()).decode()
        with open("/dev/tty", "w") as tty:
            tty.write(f"\033]52;c;{b64}\007")
        print(
            f"[mlf] copied via OSC52: {payload[:12]}{'…' if len(payload) > 12 else ''}",
            file=sys.stderr,
        )
        return 0
    except OSError as e:
        print(
            f"mlf copy: no clipboard provider available and OSC52 fallback failed ({e}).\n"
            "  Install pbcopy/wl-copy/xclip, or run inside a TTY that supports OSC 52.",
            file=sys.stderr,
        )
        return 1


def fetch_histories(
    client: "MlflowClient",
    run_id: str,
    keys: list[str],
) -> tuple[dict[str, tuple[list[int], list[float]]], list[tuple[str, str]]]:
    """Fetch metric history for every key. Skip-on-error per key.

    Returns (series, skipped) where:
      series  = {key: (steps_sorted, values_aligned), ...}
      skipped = [(key, "ExceptionType: message"), ...]

    One slow / broken key (commonly a `system.*` metric over a flaky link)
    shouldn't abort the whole batch — both the CLI `mlf plot` and the TUI
    Plot tab surface skipped keys in a separate warning instead. Bump
    MLFLOW_HTTP_REQUEST_TIMEOUT for the whole invocation if a host needs
    longer per-key reads.
    """
    series: dict[str, tuple[list[int], list[float]]] = {}
    skipped: list[tuple[str, str]] = []
    for key in keys:
        try:
            history = client.get_metric_history(run_id, key)
        except Exception as e:  # noqa: BLE001
            skipped.append((key, f"{type(e).__name__}: {str(e).splitlines()[0][:80]}"))
            continue
        if not history:
            continue
        sorted_hist = sorted(history, key=lambda m: m.step)
        steps = [m.step for m in sorted_hist]
        values = [m.value for m in sorted_hist]
        series[key] = (steps, values)
    return series, skipped
