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

    import mlflow
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
