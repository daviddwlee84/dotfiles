#!/usr/bin/env python3
"""Sync the claude-hud plugin into Claude Code's versioned plugin cache.

This helper is shared by:
- the coding_agents ansible role for first-install only
- scripts/upgrade_tools.sh for explicit refreshes via `just upgrade-plugins`

It keeps older cached versions on disk while updating installed_plugins.json to
the latest versioned checkout.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

GITHUB_API_LATEST = "https://api.github.com/repos/jarrodwatts/claude-hud/releases/latest"
PLUGIN_KEY = "claude-hud@claude-hud"
PLUGIN_REPO = "https://github.com/jarrodwatts/claude-hud.git"
USER_AGENT = "chezmoi-claude-hud-sync"


@dataclass(frozen=True)
class ReleaseInfo:
    tag: str
    version: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--home",
        type=Path,
        default=Path.home(),
        help="Home directory to manage (defaults to the current user's home).",
    )
    parser.add_argument(
        "--only-if-installed",
        action="store_true",
        help="Skip without network access when claude-hud is not already installed.",
    )
    parser.add_argument(
        "--only-if-missing",
        action="store_true",
        help="Skip without network access when claude-hud is already installed.",
    )
    parser.add_argument(
        "--version",
        help="Optional version override (for example: 0.0.12 or v0.0.12).",
    )
    return parser.parse_args()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def normalize_tag(version_or_tag: str) -> str:
    return version_or_tag if version_or_tag.startswith("v") else f"v{version_or_tag}"


def read_json(path: Path, default: dict) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def run(cmd: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def get_release(version_override: str | None) -> ReleaseInfo:
    if version_override:
        tag = normalize_tag(version_override.strip())
        return ReleaseInfo(tag=tag, version=tag.removeprefix("v"))

    request = urllib.request.Request(
        GITHUB_API_LATEST,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)

    tag = payload["tag_name"]
    return ReleaseInfo(tag=tag, version=tag.removeprefix("v"))


def get_paths(home: Path) -> tuple[Path, Path]:
    cache_root = home / ".claude" / "plugins" / "cache" / "claude-hud" / "claude-hud"
    installed_plugins = home / ".claude" / "plugins" / "installed_plugins.json"
    return cache_root, installed_plugins


def has_cached_version(cache_root: Path) -> bool:
    return any(path.is_dir() for path in cache_root.glob("*"))


def has_plugin_entry(installed_plugins: Path) -> bool:
    data = read_json(installed_plugins, {"version": 2, "plugins": {}})
    return bool(data.get("plugins", {}).get(PLUGIN_KEY))


def is_installed(home: Path) -> bool:
    cache_root, installed_plugins = get_paths(home)
    return has_cached_version(cache_root) or has_plugin_entry(installed_plugins)


def ensure_checkout(cache_root: Path, release: ReleaseInfo) -> tuple[Path, str, bool]:
    destination = cache_root / release.version
    if destination.exists():
        commit = run(["git", "rev-parse", "HEAD"], cwd=destination)
        return destination, commit, False

    cache_root.mkdir(parents=True, exist_ok=True)
    temp_dir = Path(tempfile.mkdtemp(prefix=f".{release.version}.", dir=cache_root))
    try:
        run(["git", "clone", "--depth", "1", "--branch", release.tag, PLUGIN_REPO, str(temp_dir)])
        temp_dir.rename(destination)
    except Exception:
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise

    commit = run(["git", "rev-parse", "HEAD"], cwd=destination)
    return destination, commit, True


def update_installed_plugins(installed_plugins: Path, version: str, commit: str, home: Path) -> bool:
    data = read_json(installed_plugins, {"version": 2, "plugins": {}})
    plugins = data.setdefault("plugins", {})
    existing_entries = plugins.get(PLUGIN_KEY, [])

    installed_at = now_iso()
    for entry in existing_entries:
        if entry.get("version") == version and entry.get("installedAt"):
            installed_at = entry["installedAt"]
            break

    entry = {
        "scope": "user",
        "installPath": str(home / ".claude" / "plugins" / "cache" / "claude-hud" / "claude-hud" / version),
        "version": version,
        "installedAt": installed_at,
        "lastUpdated": now_iso(),
        "gitCommitSha": commit,
    }

    if existing_entries == [entry]:
        return False

    plugins[PLUGIN_KEY] = [entry]
    write_json(installed_plugins, data)
    return True


def emit_status(status: str, **fields: str) -> None:
    parts = [f"status={status}"]
    for key, value in fields.items():
        parts.append(f"{key}={value}")
    print(" ".join(parts))


def main() -> int:
    args = parse_args()
    home = args.home.expanduser().resolve()
    installed = is_installed(home)

    if args.only_if_installed and not installed:
        emit_status("skipped", reason="not-installed")
        return 0
    if args.only_if_missing and installed:
        emit_status("skipped", reason="already-installed")
        return 0

    release = get_release(args.version)
    cache_root, installed_plugins = get_paths(home)
    destination, commit, cloned = ensure_checkout(cache_root, release)
    metadata_changed = update_installed_plugins(installed_plugins, release.version, commit, home)

    if cloned or metadata_changed:
        emit_status("changed", version=release.version, commit=commit, path=str(destination))
    else:
        emit_status("unchanged", version=release.version, commit=commit, path=str(destination))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - top-level CLI safety
        print(f"status=error error={type(exc).__name__}:{exc}", file=sys.stderr)
        raise
