"""ytmv doctor — probe the environment before you find out the hard way.

Checks every external thing ``ytmv get`` depends on and prints the resolved
profile, so "my player shows nothing" can be triaged without a download. The
libass check is the important one: Homebrew-core's plain ``ffmpeg`` is built
without it, which makes ``--burn-subs`` impossible.

``--list-profiles`` prints one profile name per line and is what the shell
completions call.
"""
from __future__ import annotations

import shutil
import sys
from dataclasses import dataclass
from typing import Annotated

import tyro

from scripts.ytmv import (
    LRCLIB_BASE,
    config_dir,
    default_out_dir,
    ffmpeg_bin,
    has_libass,
    load_config,
    profile_names,
    resolve_profile,
)


@dataclass
class Args:
    profile: Annotated[
        str, tyro.conf.arg(help="Profile to resolve and display (default: config/safe).")
    ] = ""
    list_profiles: Annotated[
        bool, tyro.conf.arg(help="Print known profile names, one per line, and exit.")
    ] = False
    offline: Annotated[
        bool, tyro.conf.arg(help="Skip the LRCLIB reachability check.")
    ] = False
    json_out: Annotated[
        bool, tyro.conf.arg(name="json", help="Emit JSON instead of a table.")
    ] = False


def _check_import(module: str) -> tuple[bool, str]:
    """Import-check a dependency and report its version.

    Neither yt-dlp nor mutagen exposes a top-level ``__version__``, so fall
    back to importlib.metadata rather than printing a useless '?'.
    """
    try:
        mod = __import__(module)
    except ImportError as e:
        return False, str(e)
    version = getattr(mod, "__version__", None) or getattr(mod, "version_string", None)
    if not version:
        from importlib.metadata import PackageNotFoundError, version as pkg_version

        try:
            version = pkg_version({"yt_dlp": "yt-dlp"}.get(module, module))
        except PackageNotFoundError:
            version = "?"
    return True, str(version)


def _check_lrclib() -> tuple[bool, str]:
    import httpx

    try:
        response = httpx.get(
            f"{LRCLIB_BASE}/search", params={"q": "test"}, timeout=8.0,
            headers={"User-Agent": "ytmv-doctor"},
        )
    except httpx.HTTPError as e:
        return False, type(e).__name__
    return response.status_code == 200, f"HTTP {response.status_code}"


def cli(args: Args) -> int:
    cfg = load_config()

    if args.list_profiles:
        for name in profile_names(cfg):
            print(name)
        return 0

    try:
        settings = resolve_profile(cfg, args.profile)
    except KeyError as e:
        print(f"ytmv doctor: {e}", file=sys.stderr)
        return 2

    checks: list[tuple[str, bool, str, str]] = []  # name, ok, detail, hint

    uv = shutil.which("uv")
    checks.append(("uv", bool(uv), uv or "not found", "install uv (see README)"))

    ok, detail = _check_import("yt_dlp")
    checks.append(("yt-dlp", ok, detail, "PEP723 dep; try `uv cache clean`"))

    ok, detail = _check_import("mutagen")
    checks.append(("mutagen", ok, detail, "PEP723 dep; needed for all ID3 tagging"))

    ok, detail = _check_import("httpx")
    checks.append(("httpx", ok, detail, "PEP723 dep; needed for LRCLIB"))

    ffmpeg = ffmpeg_bin(cfg)
    checks.append((
        "ffmpeg", bool(ffmpeg), ffmpeg or "not found",
        "chezmoi prompt installMediaTools=true, or set ffmpeg= in config.toml",
    ))

    libass = bool(ffmpeg) and has_libass(ffmpeg)
    checks.append((
        "ffmpeg libass (--burn-subs)", libass,
        "subtitles filter present" if libass else "no 'subtitles' filter",
        "brew install ffmpeg-full  (keg-only, does not shadow ffmpeg)",
    ))

    cookie_src = "none configured"
    cookie_ok = False
    try:
        from scripts.yth import load_config as yth_config

        ycfg = yth_config()
        if cfg.get("cookiefile") or cfg.get("from_browser"):
            cookie_src = f"ytmv config ({cfg.get('cookiefile') or cfg.get('from_browser')})"
            cookie_ok = True
        elif ycfg.get("cookiefile") or ycfg.get("from_browser"):
            cookie_src = f"yth config ({ycfg.get('cookiefile') or ycfg.get('from_browser')})"
            cookie_ok = True
    except ImportError as e:
        cookie_src = f"scripts.yth unavailable: {e}"
    checks.append((
        "cookies", cookie_ok, cookie_src,
        "optional; needed when YouTube demands 'confirm you're not a bot'",
    ))

    out_dir = default_out_dir()
    if cfg.get("out"):
        from pathlib import Path

        out_dir = Path(str(cfg["out"])).expanduser()
    writable = False
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        probe = out_dir / ".ytmv-write-probe"
        probe.write_text("", encoding="utf-8")
        probe.unlink()
        writable = True
    except OSError as e:
        checks.append(("output dir", False, f"{out_dir}: {e}", "set out= in config.toml"))
    if writable:
        checks.append(("output dir", True, str(out_dir), ""))

    if not args.offline:
        ok, detail = _check_lrclib()
        checks.append(("lrclib.net", ok, detail, "network/DNS; --offline to skip"))

    if args.json_out:
        import json

        print(json.dumps(
            {
                "profile": settings,
                "config": str(config_dir() / "config.toml"),
                "checks": [
                    {"name": n, "ok": o, "detail": d, "hint": h} for n, o, d, h in checks
                ],
            },
            indent=2, ensure_ascii=False,
        ))
        return 0 if all(o for _, o, _, _ in checks) else 1

    from rich.console import Console
    from rich.table import Table

    console = Console()
    table = Table(title=f"ytmv doctor — profile '{settings['_name']}'")
    table.add_column("check")
    table.add_column("")
    table.add_column("detail", overflow="fold")
    for name, ok, detail, hint in checks:
        mark = "[green]OK[/green]" if ok else "[red]--[/red]"
        text = detail if ok or not hint else f"{detail}\n[dim]{hint}[/dim]"
        table.add_row(name, mark, text)
    console.print(table)

    settings_table = Table(title="resolved profile settings")
    settings_table.add_column("setting")
    settings_table.add_column("value")
    for key, value in settings.items():
        if key != "_name":
            settings_table.add_row(key, str(value))
    console.print(settings_table)
    console.print(f"[dim]config: {config_dir() / 'config.toml'}[/dim]")

    # Cookies being unset is normal, not a failure — don't fail the exit code on it.
    required = [ok for name, ok, _, _ in checks if name not in ("cookies", "lrclib.net")]
    return 0 if all(required) else 1


def main() -> int:
    return cli(tyro.cli(Args, prog="ytmv doctor"))


if __name__ == "__main__":
    sys.exit(main())
