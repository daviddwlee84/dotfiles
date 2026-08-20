"""ytmv doctor — validate the real public-download stack before downloading.

The normal path is deliberately cookie-free. ``--cookies`` is an explicit,
opt-in probe of the configured yth/ytmv cookie source; it never prints cookie
contents or Keychain secrets. ``--offline`` keeps a stable JSON schema by
reporting network checks as skipped rather than omitting them.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version as pkg_version
from pathlib import Path
from typing import Annotated, Literal

import tyro

from scripts.yth import CookieSourceError
from scripts.ytmv import (
    LRCLIB_BASE,
    config_dir,
    cookie_options,
    default_out_dir,
    ffmpeg_bin,
    has_libass,
    load_config,
    profile_names,
    resolve_cookie_config,
    resolve_profile,
    yt_dlp_runtime_opts,
    ytdl,
)

_PUBLIC_PROBE_URL = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
Status = Literal["ok", "warn", "fail", "skip"]


@dataclass
class Args:
    profile: Annotated[
        str, tyro.conf.arg(help="Profile to resolve and display (default: config/safe).")
    ] = ""
    list_profiles: Annotated[
        bool, tyro.conf.arg(help="Print known profile names, one per line, and exit.")
    ] = False
    offline: Annotated[
        bool, tyro.conf.arg(help="Skip public YouTube and LRCLIB network probes.")
    ] = False
    cookies: Annotated[
        bool,
        tyro.conf.arg(
            help="Also load/decrypt the configured cookie source against a public probe."
        ),
    ] = False
    json_out: Annotated[
        bool, tyro.conf.arg(name="json", help="Emit JSON instead of a table.")
    ] = False


@dataclass(frozen=True)
class Check:
    id: str
    name: str
    status: Status
    detail: str
    remediation: str = ""
    required: bool = True

    @property
    def ok(self) -> bool:
        """Warnings/skips do not make the command fail; status preserves nuance."""
        return self.status != "fail"

    def as_json(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "ok": self.ok,
            "status": self.status,
            "required": self.required,
            "detail": self.detail,
            # Keep the old key as a compatibility alias for existing jq snippets.
            "hint": self.remediation,
            "remediation": self.remediation,
        }


def _check_import(module: str, distribution: str | None = None) -> tuple[bool, str]:
    try:
        mod = __import__(module)
    except ImportError as e:
        return False, str(e)
    exposed = getattr(mod, "__version__", None) or getattr(mod, "version_string", None)
    if exposed:
        return True, str(exposed)
    try:
        return True, pkg_version(distribution or module)
    except PackageNotFoundError:
        return True, "?"


def _check_distribution(distribution: str) -> tuple[bool, str]:
    try:
        return True, pkg_version(distribution)
    except PackageNotFoundError:
        return False, "not installed"


def _node_check() -> Check:
    node = shutil.which("node")
    remediation = (
        "reload the mise-enabled shell; run `mise install` and `mise which node` "
        "(yt-dlp EJS requires Node 22+)"
    )
    if not node:
        return Check("node", "Node JavaScript runtime", "fail", "not found", remediation)
    try:
        result = subprocess.run(
            [node, "--version"], capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return Check("node", "Node JavaScript runtime", "fail", type(e).__name__, remediation)
    text = result.stdout.strip() or result.stderr.strip() or f"exit {result.returncode}"
    try:
        major = int(text.lstrip("v").split(".", 1)[0])
    except ValueError:
        major = 0
    status: Status = "ok" if result.returncode == 0 and major >= 22 else "fail"
    return Check("node", "Node JavaScript runtime", status, f"{text} ({node})", remediation)


def _check_lrclib() -> tuple[bool, str]:
    import httpx

    try:
        response = httpx.get(
            f"{LRCLIB_BASE}/search",
            params={"q": "test"},
            timeout=8.0,
            headers={"User-Agent": "ytmv-doctor"},
        )
    except httpx.HTTPError as e:
        return False, type(e).__name__
    return response.status_code == 200, f"HTTP {response.status_code}"


class _CookieProbeLogger:
    """Suppress yt-dlp output while retaining a value-free cookie-warning bit."""

    _COOKIE_TERMS = (
        "cookie", "decrypt", "keyring", "keychain", "find-generic-password",
        "local state", "secretstorage", "kwallet", "networkwallet", "profile",
    )

    def __init__(self) -> None:
        self.cookie_issue = False

    def _record(self, message: object) -> None:
        text = str(message).lower()
        if any(term in text for term in self._COOKIE_TERMS):
            self.cookie_issue = True

    def debug(self, _message: object) -> None:
        pass

    def info(self, _message: object) -> None:
        pass

    def warning(self, message: object) -> None:
        self._record(message)

    def error(self, message: object) -> None:
        self._record(message)


def _youtube_probe(
    cookies: dict | None = None, *, require_input_cookie: bool = False
) -> tuple[bool, str]:
    logger = _CookieProbeLogger() if require_input_cookie else None
    opts = {
        "quiet": True,
        "noprogress": True,
        "skip_download": True,
        **yt_dlp_runtime_opts(),
        **(cookies or {}),
    }
    if logger:
        opts["logger"] = logger
    try:
        with ytdl().YoutubeDL(opts) as ydl:
            if require_input_cookie:
                usable = [
                    cookie
                    for cookie in ydl.cookiejar
                    if not cookie.is_expired()
                    and (
                        cookie.domain.lstrip(".").lower() == "youtube.com"
                        or cookie.domain.lstrip(".").lower().endswith(".youtube.com")
                    )
                ]
                if logger and logger.cookie_issue:
                    return False, "cookie source emitted a load/decryption warning"
                if not usable:
                    return False, "source loaded zero usable YouTube-domain cookies"
            info = ydl.extract_info(_PUBLIC_PROBE_URL, download=False)
            if logger and logger.cookie_issue:
                return False, "cookie source emitted a load/decryption warning"
    except Exception as e:  # noqa: BLE001 — report the extractor's first useful line
        text = str(e).splitlines()[0][:240] if str(e) else type(e).__name__
        return False, text
    title = (info or {}).get("title") or "metadata returned"
    return True, str(title)[:160]


def _cookie_failure(required: bool, check_id: str, detail: str, remediation: str) -> Check:
    return Check(
        check_id,
        "cookie source",
        "fail" if required else "warn",
        detail,
        remediation,
        required=required,
    )


def _validate_cookie_source(cfg: dict, required: bool) -> tuple[Check, dict | None]:
    effective, owner = resolve_cookie_config(cfg)
    if not effective:
        if required:
            return (
                _cookie_failure(
                    True,
                    "cookie-source",
                    "none configured",
                    "configure yth's cookie source; see `ytmv help` section 3",
                ),
                None,
            )
        return (
            Check(
                "cookie-source",
                "cookie source",
                "skip",
                "none configured (normal for public videos)",
                "configure only for private/restricted content or an intentional bot-check retry",
                required=False,
            ),
            None,
        )

    cookiefile = effective.get("cookiefile")
    if cookiefile:
        path = Path(os.path.expanduser(str(cookiefile)))
        remediation = (
            "export a YouTube-only Netscape cookie file, then `chmod 600 "
            "~/.config/yth/cookies.txt`; never print or commit it"
        )
        if not path.is_file():
            return (
                _cookie_failure(
                    required, "cookie-source", f"{owner} cookie file missing", remediation
                ),
                None,
            )
        try:
            size = path.stat().st_size
            mode = stat.S_IMODE(path.stat().st_mode)
        except OSError as e:
            return (
                _cookie_failure(
                    required, "cookie-source", f"cannot stat cookie file: {e}", remediation
                ),
                None,
            )
        if size == 0:
            return (
                _cookie_failure(
                    required, "cookie-source", f"{owner} cookie file is empty", remediation
                ),
                None,
            )
        if os.name != "nt" and mode & 0o077:
            return (
                _cookie_failure(
                    required,
                    "cookie-source",
                    f"{owner} cookie file mode is {mode:04o}, expected 0600",
                    remediation,
                ),
                None,
            )
        try:
            options = cookie_options(cfg, True)
        except CookieSourceError as e:
            return _cookie_failure(required, "cookie-source", str(e), remediation), None
        return (
            Check(
                "cookie-source",
                "cookie source",
                "ok",
                f"{owner} cookie file is safe, YouTube-only, mode {mode:04o}",
                required=required,
            ),
            options,
        )

    spec = str(effective.get("from_browser") or "")
    browser, separator, profile_path = spec.partition(":")
    browser = browser.strip().lower()
    profile_path = profile_path.strip() if separator else ""
    supported_browsers = {
        "brave", "chrome", "chromium", "edge", "firefox", "opera",
        "safari", "vivaldi", "whale",
    }
    if browser in {"arc", "zen"}:
        recommendation = (
            "use the isolated YouTube-only Arc export in `ytmv help` section 4"
            if browser == "arc"
            else 'use `from_browser = "firefox:/absolute/path/to/zen/profile"`'
        )
        return (
            _cookie_failure(
                required,
                "cookie-source",
                f"{browser} is not a supported yt-dlp browser name",
                recommendation,
            ),
            None,
        )
    if browser and browser not in supported_browsers:
        return (
            _cookie_failure(
                required,
                "cookie-source",
                f"unsupported yt-dlp browser name: {browser}",
                "use a supported browser name or an isolated YouTube-only cookie file",
            ),
            None,
        )
    if browser == "firefox" and profile_path:
        profile = Path(os.path.expanduser(profile_path))
        if not (profile / "cookies.sqlite").is_file():
            return (
                _cookie_failure(
                    required,
                    "cookie-source",
                    f"{owner} Firefox-compatible profile has no cookies.sqlite",
                    "set from_browser to an absolute Firefox/Zen profile directory",
                ),
                None,
            )

    if platform.system() == "Darwin" and browser == "chrome":
        try:
            result = subprocess.run(
                [
                    "/usr/bin/security",
                    "find-generic-password",
                    "-a",
                    "Chrome",
                    "-s",
                    "Chrome Safe Storage",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            return (
                _cookie_failure(
                    required,
                    "cookie-source",
                    f"Chrome Keychain metadata query failed: {type(e).__name__}",
                    "see `ytmv help` section 5; do not use a command that prints the secret",
                ),
                None,
            )
        if result.returncode == 44:
            return (
                _cookie_failure(
                    required,
                    "cookie-source",
                    "Chrome Safe Storage item not found "
                    "(status 44 / OSStatus -25300); no popup is expected",
                    "use a dedicated supported-browser profile or isolated YouTube-only export",
                ),
                None,
            )
        if result.returncode != 0:
            return (
                _cookie_failure(
                    required,
                    "cookie-source",
                    f"Chrome Keychain metadata query failed (status {result.returncode})",
                    "see `ytmv help` section 5; do not use a command that prints the secret",
                ),
                None,
            )

    if not browser:
        return (
            _cookie_failure(
                required,
                "cookie-source",
                "empty from_browser value",
                "set a supported browser/profile",
            ),
            None,
        )
    try:
        options = cookie_options(cfg, True)
    except CookieSourceError as e:
        return (
            _cookie_failure(
                required, "cookie-source", str(e), "repair the configured source"
            ),
            None,
        )
    return (
        Check(
            "cookie-source",
            "cookie source",
            "ok",
            f"{owner} browser source: {browser}",
            required=required,
        ),
        options,
    )


def _output_check(cfg: dict) -> Check:
    out_dir = Path(str(cfg.get("out"))).expanduser() if cfg.get("out") else default_out_dir()
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        probe = out_dir / ".ytmv-write-probe"
        probe.write_text("", encoding="utf-8")
        probe.unlink()
    except OSError as e:
        return Check(
            "output-dir",
            "output directory",
            "fail",
            f"{out_dir}: {e}",
            "set `out =` in ~/.config/ytmv/config.toml",
        )
    return Check("output-dir", "output directory", "ok", str(out_dir))


def _exit_code(checks: list[Check]) -> int:
    return 1 if any(check.required and check.status == "fail" for check in checks) else 0


def _render_table(checks: list[Check], settings: dict) -> None:
    from rich.console import Console
    from rich.table import Table

    console = Console()
    table = Table(title=f"ytmv doctor — profile '{settings['_name']}'")
    table.add_column("check")
    table.add_column("")
    table.add_column("detail", overflow="fold")
    marks = {
        "ok": "[green]OK[/green]",
        "warn": "[yellow]WARN[/yellow]",
        "fail": "[red]FAIL[/red]",
        "skip": "[dim]SKIP[/dim]",
    }
    for check in checks:
        text = check.detail
        if check.remediation and check.status != "ok":
            text += f"\n[dim]{check.remediation}[/dim]"
        table.add_row(check.name, marks[check.status], text)
    console.print(table)

    settings_table = Table(title="resolved profile settings")
    settings_table.add_column("setting")
    settings_table.add_column("value")
    for key, value in settings.items():
        if key != "_name":
            settings_table.add_row(key, str(value))
    console.print(settings_table)
    console.print(f"[dim]config: {config_dir() / 'config.toml'}[/dim]")


def cli(args: Args) -> int:
    cfg = load_config()

    if args.list_profiles:
        for name in profile_names(cfg):
            print(name)
        return 0
    if args.offline and args.cookies:
        print("ytmv doctor: --offline and --cookies cannot be used together", file=sys.stderr)
        return 2

    try:
        settings = resolve_profile(cfg, args.profile)
    except KeyError as e:
        print(f"ytmv doctor: {e}", file=sys.stderr)
        return 2

    checks: list[Check] = []
    uv = shutil.which("uv")
    checks.append(
        Check(
            "uv",
            "uv",
            "ok" if uv else "fail",
            uv or "not found",
            "install uv (see README)",
        )
    )

    ok, detail = _check_import("yt_dlp", "yt-dlp")
    checks.append(
        Check(
            "yt-dlp",
            "yt-dlp",
            "ok" if ok else "fail",
            detail,
            "PEP 723 dependency; run `uv cache clean` if its environment is corrupt",
        )
    )
    ok, detail = _check_distribution("yt-dlp-ejs")
    checks.append(
        Check(
            "yt-dlp-ejs",
            "yt-dlp EJS solver",
            "ok" if ok else "fail",
            detail,
            "refresh this PEP 723 environment: `uv run --reinstall-package "
            "yt-dlp-ejs --script ~/.dotfiles/bin/ytmv doctor --offline`",
        )
    )
    checks.append(_node_check())

    for check_id, module, distribution, label, remediation in (
        ("mutagen", "mutagen", "mutagen", "mutagen", "needed for ID3 tagging"),
        ("httpx", "httpx", "httpx", "httpx", "needed for LRCLIB lyrics"),
    ):
        ok, detail = _check_import(module, distribution)
        checks.append(
            Check(check_id, label, "ok" if ok else "fail", detail, remediation)
        )

    ffmpeg = ffmpeg_bin(cfg)
    checks.append(
        Check(
            "ffmpeg",
            "ffmpeg",
            "ok" if ffmpeg else "fail",
            ffmpeg or "not found",
            "run `dotcfg --set installMediaTools=true --yes`, or set `ffmpeg =` in config",
        )
    )
    libass = bool(ffmpeg) and has_libass(ffmpeg)
    checks.append(
        Check(
            "libass",
            "ffmpeg libass (--burn-subs)",
            "ok" if libass else "warn",
            "subtitles filter present" if libass else "no 'subtitles' filter",
            "macOS: install keg-only ffmpeg-full; plain Homebrew ffmpeg lacks libass",
            required=False,
        )
    )
    checks.append(_output_check(cfg))

    cookie_check, effective_cookies = _validate_cookie_source(cfg, required=args.cookies)
    checks.append(cookie_check)

    if args.offline:
        checks.extend(
            [
                Check(
                    "youtube-public",
                    "public YouTube metadata",
                    "skip",
                    "offline mode",
                    required=True,
                ),
                Check(
                    "lrclib",
                    "lrclib.net",
                    "skip",
                    "offline mode",
                    required=False,
                ),
            ]
        )
    else:
        ok, detail = _youtube_probe()
        checks.append(
            Check(
                "youtube-public",
                "public YouTube metadata",
                "ok" if ok else "fail",
                detail,
                "fix EJS/Node first, then try a clean residential IP and wait before retrying",
                required=True,
            )
        )
        ok, detail = _check_lrclib()
        checks.append(
            Check(
                "lrclib",
                "lrclib.net",
                "ok" if ok else "warn",
                detail,
                "optional lyrics service; check network/DNS or retry later",
                required=False,
            )
        )
        if args.cookies:
            if effective_cookies is None:
                checks.append(
                    Check(
                        "youtube-cookies",
                        "cookie loading/decryption",
                        "skip",
                        "cookie source validation failed",
                        required=True,
                    )
                )
            else:
                ok, detail = _youtube_probe(effective_cookies, require_input_cookie=True)
                checks.append(
                    Check(
                        "youtube-cookies",
                        "cookie loading/decryption",
                        "ok" if ok else "fail",
                        detail,
                        "this tests source loading only; re-export/repair the "
                        "dedicated source without printing it",
                        required=True,
                    )
                )

    if args.json_out:
        print(
            json.dumps(
                {
                    "profile": settings,
                    "config": str(config_dir() / "config.toml"),
                    "checks": [check.as_json() for check in checks],
                },
                indent=2,
                ensure_ascii=False,
            )
        )
    else:
        _render_table(checks, settings)
    return _exit_code(checks)


def main() -> int:
    return cli(tyro.cli(Args, prog="ytmv doctor"))


if __name__ == "__main__":
    sys.exit(main())
