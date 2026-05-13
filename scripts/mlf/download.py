"""mlf download — pull a registered model's artifacts to a local dir.

Resolves `name@version` (numeric), `name@alias`, or bare `name` (latest by
creation_timestamp) to a `ModelVersion`, then downloads via
`mlflow.artifacts.download_artifacts(artifact_uri=mv.source, dst_path=...)`.

Stdout = absolute destination path (for piping into `cd $(mlf download …)`
or `mlflow models serve -m $(mlf download …)`).  All diagnostics → stderr.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

import tyro

from scripts.mlf import make_client, tracking_uri


@dataclass
class Args:
    target: Annotated[
        str,
        tyro.conf.Positional,
        tyro.conf.arg(
            help=(
                "Model spec. Forms: `name`, `name@version` (e.g. MyModel@3), "
                "or `name@alias` (e.g. MyModel@Champion). Bare `name` "
                "resolves to the most recently created version."
            ),
        ),
    ]
    dest: Annotated[
        str | None,
        tyro.conf.arg(
            help=(
                "Destination directory. Default: ./<name>-<version>/. "
                "Created if missing; non-empty dirs are accepted (mlflow "
                "may overlay files)."
            ),
        ),
    ] = None


def _resolve_version(client, name: str, suffix: str | None):
    """Return a ModelVersion for the given name + optional @version|@alias.

    suffix=None or 'latest' → most recent by creation_timestamp.
    Numeric suffix → exact version lookup.
    Else → alias lookup.
    """
    if suffix is None or suffix == "latest":
        candidates = list(client.search_model_versions(f"name='{name}'"))
        if not candidates:
            raise RuntimeError(f"no versions registered for model '{name}'")
        return max(candidates, key=lambda v: v.creation_timestamp)
    if suffix.isdigit():
        return client.get_model_version(name=name, version=suffix)
    return client.get_model_version_by_alias(name=name, alias=suffix)


def _dir_size(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += (Path(root) / f).stat().st_size
            except OSError:
                pass
    return total


def _human(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}{unit}"
        n //= 1024
    return f"{n}B"


def cli(args: Args) -> int:
    name, _, suffix = args.target.partition("@")
    suffix = suffix or None
    if not name:
        print(
            "mlf download: empty model name. Use: mlf download <name>[@<version|alias>]",
            file=sys.stderr,
        )
        return 2

    client = make_client()
    try:
        mv = _resolve_version(client, name, suffix)
    except Exception as e:  # noqa: BLE001
        print(
            f"mlf download: cannot resolve '{args.target}'\n"
            f"  tracking_uri: {tracking_uri()}\n"
            f"  {type(e).__name__}: {str(e).splitlines()[0][:200]}",
            file=sys.stderr,
        )
        return 1

    dest = Path(args.dest or f"./{name}-{mv.version}").resolve()
    dest.mkdir(parents=True, exist_ok=True)

    print(
        f"[mlf] resolving {name}@{suffix or 'latest'} -> version={mv.version} run_id={mv.run_id}",
        file=sys.stderr,
    )
    print(f"[mlf] source: {mv.source}", file=sys.stderr)
    print(f"[mlf] dest:   {dest}", file=sys.stderr)

    import mlflow.artifacts

    try:
        local = mlflow.artifacts.download_artifacts(
            artifact_uri=mv.source, dst_path=str(dest)
        )
    except Exception as e:  # noqa: BLE001
        print(
            f"mlf download: artifact fetch failed — {type(e).__name__}: {str(e).splitlines()[0][:200]}",
            file=sys.stderr,
        )
        return 1

    local_path = Path(local).resolve()
    size = _dir_size(local_path)
    print(f"[mlf] downloaded {_human(size)} -> {local_path}", file=sys.stderr)
    print(
        f"[mlf] hint: mlflow models serve -m {local_path} --port 5000",
        file=sys.stderr,
    )
    print(local_path)
    return 0


def main() -> int:
    return cli(tyro.cli(Args, prog="mlf download"))


if __name__ == "__main__":
    sys.exit(main())
