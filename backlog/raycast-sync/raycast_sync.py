#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
Raycast config sync for non-Pro users.

!!! PAUSED — SEE ../raycast-sync-non-pro.md !!!

Raycast's `.rayconfig` bulk export is AES-encrypted with a non-public KDF
that mixes keychain-bound material in; we empirically ruled out every
standard scheme with password `12345678`. This script therefore fails at
the `rayconfig_to_json` step on real exports. The rest (redaction,
extensions-manifest walker, secrets.env.example emitter, AppleScript
fallback, import plumbing) is intact and should be reusable once the
format blocker is resolved — see the backlog doc for revival paths.

---

Raycast Pro offers cloud sync; non-Pro users have no official cross-machine
path. Syncing ~/Library/Application Support/com.raycast.macos/ directly does
NOT work — raycast-enc.sqlite is encrypted with a per-machine Keychain key
and macOS Sonoma+ breaks symlinked Library preferences.

What DOES work is Raycast's built-in Export/Import (Settings -> Advanced)
which produces a .rayconfig file (gzipped JSON ONLY when the export
password field is empty — which Raycast currently does not allow). This
tool wraps that workflow: export -> decompress -> redact -> git-commit
friendly tree -> on a fresh machine, reinstall extensions + import.

Extension API keys / OAuth tokens live in the Keychain and are NOT in the
export; they have to be re-entered per machine. The tool emits a
secrets.env.example checklist to make that obvious.

Usage:
    raycast_sync.py export [--out DIR] [--auto-gui] [--rayconfig PATH]
    raycast_sync.py redact [--dir DIR]
    raycast_sync.py import [--dir DIR] [--auto-gui] [--skip-extensions]
    raycast_sync.py diff   [--dir DIR]
    raycast_sync.py inspect PATH        # decompress .rayconfig -> stdout
"""
from __future__ import annotations

import argparse
import difflib
import getpass
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_DIR = Path("raycast")
DEFAULT_RAYCONFIG_NAME = "raycast.rayconfig"
JSON_NAME = "raycast.json"
MANIFEST_NAME = "extensions.json"
SECRETS_EXAMPLE_NAME = "secrets.env.example"

# Keys whose value is replaced with <REDACTED> wherever they appear.
# Case-insensitive match on the JSON key.
REDACT_KEY_RE = re.compile(
    r"(password|secret|token|apikey|api_key|access_key|access_token|"
    r"refresh_token|client_secret|private_key|cookie|authorization|"
    r"bearer|credential)",
    re.IGNORECASE,
)

REDACTED = "<REDACTED>"
HOME = Path.home()
USERNAME = getpass.getuser()

# Where Raycast saves exports by default. Current Raycast (1.104+) writes as
# "Raycast <YYYY-MM-DD HH.MM.SS>.rayconfig"; we glob for any new match rather
# than pinning a single filename.
DEFAULT_EXPORT_DIR = HOME / "Downloads"
EXPORT_GLOB = "*.rayconfig"

# Known-supported Raycast version range for --auto-gui AppleScript. If the
# installed version is outside this range, --auto-gui falls back to manual.
RAYCAST_GUI_MIN = (1, 100, 0)
RAYCAST_GUI_MAX = (1, 199, 999)

RAYCAST_APP = Path("/Applications/Raycast.app")


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def info(msg: str) -> None:
    print(f"==> {msg}", file=sys.stderr)


def run(cmd: list[str], check: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True, **kw)


def raycast_version() -> tuple[int, int, int] | None:
    plist = RAYCAST_APP / "Contents" / "Info.plist"
    if not plist.exists():
        return None
    try:
        out = run(
            ["defaults", "read", str(plist), "CFBundleShortVersionString"],
            check=True, capture_output=True,
        ).stdout.strip()
        parts = [int(x) for x in out.split(".")[:3]]
        while len(parts) < 3:
            parts.append(0)
        return (parts[0], parts[1], parts[2])
    except Exception:
        return None


def raycast_running() -> bool:
    r = run(["pgrep", "-x", "Raycast"], check=False, capture_output=True)
    return r.returncode == 0


def ensure_raycast_running() -> None:
    if raycast_running():
        return
    info("Launching Raycast...")
    run(["open", "-g", "-a", "Raycast"], check=False)
    for _ in range(20):
        if raycast_running():
            return
        time.sleep(0.2)


# ---------------------------------------------------------------------------
# Gzip <-> JSON (.rayconfig is gzipped JSON)
# ---------------------------------------------------------------------------


GZIP_MAGIC = b"\x1f\x8b"


def rayconfig_to_json(src: Path) -> dict:
    # .rayconfig is gzipped JSON ONLY when the user clears the password field
    # in Raycast's Export dialog. The field pre-fills with "12345678"; leaving
    # that default produces an AES-encrypted file with no standard header
    # (no `Salted__` prefix, no OpenSSL EVP_BytesToKey compatibility). We
    # cannot reverse that without reverse-engineering Raycast itself.
    with open(src, "rb") as f:
        head = f.read(2)
    if head != GZIP_MAGIC:
        die(
            f"{src} is not a gzipped JSON export (first 2 bytes: {head!r}).\n"
            "\n"
            "Raycast is encrypting your export because the 'Export Password'\n"
            "is set. The password field is NOT in the Advanced/Export dialog\n"
            "itself — you have to clear it in a different tab:\n"
            "\n"
            "  1. Raycast Settings (Cmd+,) -> Extensions tab\n"
            "  2. In the search/filter box type: export\n"
            "  3. Select 'Raycast -> Export Settings & Data'\n"
            "  4. Right pane: the 'Export Password' field pre-fills with\n"
            "     eight bullets (the default '12345678'). Click the eye\n"
            "     icon to reveal, select all, delete. Leave it EMPTY.\n"
            "  5. Back to Settings -> Advanced -> Export, export again,\n"
            "     then re-run this command.\n"
            "\n"
            "Unencrypted exports still round-trip via Import. We cannot\n"
            "decode the encrypted form — Raycast's scheme is not standard\n"
            "openssl and we've confirmed no public password-derivation path\n"
            "(PBKDF2, scrypt, SHA*, EVP_BytesToKey) matches.",
            code=2,
        )
    with gzip.open(src, "rt", encoding="utf-8") as f:
        return json.load(f)


def json_to_rayconfig(data: dict, dst: Path) -> None:
    # Raycast's own export writes compact JSON with gzip. We match that so
    # Import never complains about format.
    raw = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with gzip.open(dst, "wb") as f:
        f.write(raw)


# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------


def redact_tree(obj):
    """Walk a JSON tree; replace values under sensitive keys with REDACTED."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if isinstance(k, str) and REDACT_KEY_RE.search(k):
                # Preserve None; redact everything else.
                out[k] = REDACTED if v is not None else None
            else:
                out[k] = redact_tree(v)
        return out
    if isinstance(obj, list):
        return [redact_tree(v) for v in obj]
    if isinstance(obj, str):
        return normalize_string(obj)
    return obj


def normalize_string(s: str) -> str:
    # Strip the user's home path so diffs are stable across machines.
    if USERNAME:
        s = s.replace(f"/Users/{USERNAME}/", "$HOME/")
        s = s.replace(f"/Users/{USERNAME}", "$HOME")
    return s


def gitleaks_pass(raycast_json: Path) -> None:
    """Run the repo's existing scripts/redact_secrets.py on a copy of
    raycast.json so any secrets our key-name pass missed get caught by
    gitleaks patterns."""
    repo_redact = Path(__file__).parent / "redact_secrets.py"
    if not repo_redact.exists():
        info("scripts/redact_secrets.py not found; skipping gitleaks pass")
        return
    if shutil.which("gitleaks") is None:
        info("gitleaks not installed; skipping gitleaks pass")
        return
    # Stage the file under a temp 'raycast' dir so --paths raycast matches.
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp) / "raycast"
        tmpdir.mkdir()
        staged = tmpdir / raycast_json.name
        shutil.copy2(raycast_json, staged)
        r = run(
            [
                str(repo_redact),
                "--fix",
                "--working-dir",
                "--paths",
                "raycast",
            ],
            check=False,
            cwd=tmp,
            capture_output=True,
        )
        if r.returncode != 0:
            info(
                "gitleaks pass reported issues; check output:\n"
                + (r.stdout or "") + (r.stderr or "")
            )
        # Copy back any in-place edits.
        if staged.exists():
            shutil.copy2(staged, raycast_json)


# ---------------------------------------------------------------------------
# Extensions manifest + secrets template
# ---------------------------------------------------------------------------


def _find_extensions(data) -> list[dict]:
    """Raycast's .rayconfig schema isn't formally documented; locate the
    extensions array by walking the tree looking for a list of dicts that
    look like extensions (have 'name' + either 'author' or 'owner' + an id)."""
    found: list[dict] = []

    def looks_like_ext(d) -> bool:
        if not isinstance(d, dict):
            return False
        has_name = "name" in d and isinstance(d["name"], str)
        has_author = any(k in d for k in ("author", "owner", "authorName"))
        has_id = any(k in d for k in ("id", "extensionId", "uuid"))
        return has_name and (has_author or has_id)

    def walk(node):
        if isinstance(node, list):
            if node and all(looks_like_ext(x) for x in node):
                found.extend(node)
                return
            for v in node:
                walk(v)
        elif isinstance(node, dict):
            # Prefer an explicit 'extensions' key if present
            if "extensions" in node and isinstance(node["extensions"], list):
                arr = node["extensions"]
                if arr and all(looks_like_ext(x) for x in arr):
                    found.extend(arr)
                    return
            for v in node.values():
                walk(v)

    walk(data)
    # De-dupe by (author, name) pair
    seen = set()
    out = []
    for e in found:
        key = (
            str(e.get("author") or e.get("owner") or e.get("authorName") or ""),
            str(e.get("name") or ""),
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(e)
    return out


def build_manifest(data: dict) -> list[dict]:
    manifest: list[dict] = []
    for e in _find_extensions(data):
        author = (
            e.get("author")
            or e.get("owner")
            or e.get("authorName")
            or ""
        )
        manifest.append(
            {
                "id": e.get("id") or e.get("extensionId") or e.get("uuid") or "",
                "name": e.get("name", ""),
                "title": e.get("title", e.get("name", "")),
                "author": author,
                "version": e.get("version", ""),
                "source": (
                    "store" if e.get("source") in (None, "store") else e.get("source")
                ),
            }
        )
    manifest.sort(key=lambda m: (m["author"], m["name"]))
    return manifest


def build_secrets_example(data: dict) -> str:
    """For each extension's preferences[] entry with type==password, emit a
    commented placeholder so the user on a new machine has a checklist."""
    lines = [
        "# Raycast extension secrets to re-enter on a fresh machine.",
        "# These CANNOT be synced — Raycast stores them in macOS Keychain.",
        "# Re-enter them via Raycast -> Extensions -> <name> settings.",
        "",
    ]
    for e in _find_extensions(data):
        prefs = e.get("preferences") or []
        if not isinstance(prefs, list):
            continue
        secret_prefs = [
            p for p in prefs
            if isinstance(p, dict)
            and str(p.get("type", "")).lower() in {"password", "secret", "token"}
        ]
        if not secret_prefs:
            continue
        ext_name = e.get("name", "unknown")
        ext_author = e.get("author") or e.get("owner") or "unknown"
        lines.append(f"# {ext_author}/{ext_name}")
        for p in secret_prefs:
            title = p.get("title") or p.get("label") or p.get("name", "")
            pname = p.get("name", "pref")
            slug = re.sub(r"[^A-Za-z0-9]+", "_", f"{ext_name}_{pname}").strip("_").upper()
            lines.append(f"# {title}")
            lines.append(f"RAYCAST_{slug}=")
        lines.append("")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# AppleScript automation (best-effort; needs Accessibility permission)
# ---------------------------------------------------------------------------


APPLESCRIPT_EXPORT = r'''
tell application "Raycast" to activate
delay 0.8
tell application "System Events"
    tell process "Raycast"
        keystroke "," using command down
        delay 1.0
        -- click Advanced tab (localized label required; caller supplies)
    end tell
end tell
'''


def try_applescript(script: str) -> tuple[bool, str]:
    try:
        r = run(["osascript", "-e", script], check=False, capture_output=True)
        return (r.returncode == 0, (r.stdout + r.stderr).strip())
    except FileNotFoundError:
        return (False, "osascript not found")


def gui_version_supported() -> bool:
    v = raycast_version()
    if v is None:
        return False
    return RAYCAST_GUI_MIN <= v <= RAYCAST_GUI_MAX


# ---------------------------------------------------------------------------
# Subcommand: export
# ---------------------------------------------------------------------------


def cmd_export(args: argparse.Namespace) -> int:
    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rayconfig = resolve_rayconfig_for_export(args)
    info(f"Loading {rayconfig}")
    data = rayconfig_to_json(rayconfig)

    json_path = out_dir / JSON_NAME
    json_path.write_text(
        json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    info(f"Wrote {json_path}")

    manifest = build_manifest(data)
    (out_dir / MANIFEST_NAME).write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    info(f"Wrote {out_dir / MANIFEST_NAME} ({len(manifest)} extensions)")

    (out_dir / SECRETS_EXAMPLE_NAME).write_text(
        build_secrets_example(data), encoding="utf-8"
    )
    info(f"Wrote {out_dir / SECRETS_EXAMPLE_NAME}")

    # In-place redact after writing the raw artifacts.
    redact_inplace(json_path)
    info("Redacted raycast.json")

    write_readme(out_dir)
    return 0


def resolve_rayconfig_for_export(args: argparse.Namespace) -> Path:
    if args.rayconfig:
        p = Path(args.rayconfig).expanduser().resolve()
        if not p.exists():
            die(f"--rayconfig path does not exist: {p}")
        return p

    # Snapshot existing .rayconfig files so we only return one the user
    # creates during this run (or one touched after baseline_mtime).
    baseline = {
        p: p.stat().st_mtime
        for p in DEFAULT_EXPORT_DIR.glob(EXPORT_GLOB)
        if p.is_file()
    }

    if args.auto_gui and gui_version_supported():
        info("Attempting GUI automation (Settings -> Advanced -> Export)...")
        ensure_raycast_running()
        ok, out = try_applescript(APPLESCRIPT_EXPORT)
        if not ok:
            info(f"AppleScript failed ({out}); falling back to manual.")
        # Either way, fall through to polling — user still needs to click
        # the Export button once.

    print_manual_export_instructions()
    return poll_for_new_rayconfig(baseline, timeout=300)


def print_manual_export_instructions() -> None:
    print(
        f"""
Please export your Raycast config:

  1. Open Raycast ({'it is running' if raycast_running() else 'launch it first'})
  2. Press Cmd+, to open Settings
  3. Go to the Advanced tab
  4. Click "Export"
  5. BEFORE clicking Export: clear the Export Password.
     It lives in a DIFFERENT tab, not in the Export dialog itself:
       Settings (Cmd+,) -> Extensions -> filter "export" ->
       'Raycast -> Export Settings & Data' -> right pane 'Export
       Password' -> reveal, select all, delete, save.
     The Advanced/Export dialog has a tooltip pointing you there.
     Skipping this step produces an AES-encrypted blob we cannot decode.
  6. Save the default filename anywhere under {DEFAULT_EXPORT_DIR}
     (e.g. 'Raycast 2026-04-24 16.13.06.rayconfig' — we auto-detect)

Waiting for a new .rayconfig under {DEFAULT_EXPORT_DIR}... (Ctrl+C to abort)
""".strip(),
        file=sys.stderr,
    )


def poll_for_new_rayconfig(
    baseline: dict[Path, float], timeout: float = 300.0
) -> Path:
    """Return the first .rayconfig under DEFAULT_EXPORT_DIR that's new or
    touched after baseline_mtime. Baseline is the set of files we saw when we
    started — anything outside it (or with a newer mtime) is considered the
    fresh export."""
    start = time.time()
    while time.time() - start < timeout:
        candidates: list[tuple[float, Path]] = []
        for p in DEFAULT_EXPORT_DIR.glob(EXPORT_GLOB):
            if not p.is_file():
                continue
            mtime = p.stat().st_mtime
            prior = baseline.get(p)
            if prior is None or mtime > prior:
                candidates.append((mtime, p))
        if candidates:
            # Pick the most recently modified — that's the fresh export.
            candidates.sort(reverse=True)
            chosen = candidates[0][1]
            # Let any in-flight write settle.
            time.sleep(0.5)
            info(f"Detected new export: {chosen}")
            return chosen
        time.sleep(1.0)
    die(f"timed out waiting for a new *.rayconfig under {DEFAULT_EXPORT_DIR}")


def redact_inplace(json_path: Path) -> None:
    data = json.loads(json_path.read_text(encoding="utf-8"))
    redacted = redact_tree(data)
    json_path.write_text(
        json.dumps(redacted, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    # Secondary pass: gitleaks on the redacted file to catch anything the
    # key-name heuristic missed (URLs with embedded tokens, etc.).
    gitleaks_pass(json_path)


# ---------------------------------------------------------------------------
# Subcommand: redact
# ---------------------------------------------------------------------------


def cmd_redact(args: argparse.Namespace) -> int:
    d = Path(args.dir).resolve()
    jp = d / JSON_NAME
    if not jp.exists():
        die(f"{jp} not found; run export first")
    redact_inplace(jp)
    info(f"Redacted {jp}")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: import
# ---------------------------------------------------------------------------


def cmd_import(args: argparse.Namespace) -> int:
    d = Path(args.dir).resolve()
    jp = d / JSON_NAME
    mp = d / MANIFEST_NAME
    if not jp.exists():
        die(f"{jp} not found; nothing to import")

    data = json.loads(jp.read_text(encoding="utf-8"))

    # Step 1: reinstall store extensions via deep links (best-effort).
    if not args.skip_extensions and mp.exists():
        manifest = json.loads(mp.read_text(encoding="utf-8"))
        reinstall_extensions(manifest)

    # Step 2: re-gzip JSON back into a .rayconfig Raycast can import.
    with tempfile.TemporaryDirectory() as tmp:
        rayconfig = Path(tmp) / DEFAULT_RAYCONFIG_NAME
        json_to_rayconfig(data, rayconfig)
        # Copy to Downloads so user can pick it in the file dialog.
        visible = HOME / "Downloads" / DEFAULT_RAYCONFIG_NAME
        shutil.copy2(rayconfig, visible)
        info(f"Prepared import bundle at {visible}")

        if args.auto_gui and gui_version_supported():
            ensure_raycast_running()
            ok, out = try_applescript(APPLESCRIPT_EXPORT)
            if not ok:
                info(f"AppleScript failed ({out}); use manual import.")

        print_manual_import_instructions(visible)
    return 0


def reinstall_extensions(manifest: list[dict]) -> None:
    info(f"Reinstalling {len(manifest)} store extensions via raycast:// deep links")
    for e in manifest:
        if e.get("source") and e["source"] != "store":
            continue
        author = e.get("author", "")
        name = e.get("name", "")
        if not author or not name:
            continue
        url = f"raycast://extensions/{author}/{name}"
        run(["open", "-g", url], check=False)
        time.sleep(0.15)  # don't flood Raycast
    info("Extension install dispatched; Raycast will download in the background.")


def print_manual_import_instructions(bundle: Path) -> None:
    print(
        f"""
Import your Raycast config:

  1. Open Raycast (Cmd+Space)
  2. Cmd+, -> Advanced -> Import
  3. Select:  {bundle}

Extension reinstallation has been triggered in the background. Some
extensions need API keys/tokens — see secrets.env.example for the list.
""".strip(),
        file=sys.stderr,
    )


# ---------------------------------------------------------------------------
# Subcommand: diff
# ---------------------------------------------------------------------------


def cmd_diff(args: argparse.Namespace) -> int:
    d = Path(args.dir).resolve()
    committed = d / JSON_NAME
    if not committed.exists():
        die(f"{committed} not found")

    with tempfile.TemporaryDirectory() as tmp:
        ns = argparse.Namespace(
            out=tmp,
            auto_gui=False,
            rayconfig=args.rayconfig,
        )
        cmd_export(ns)
        fresh = Path(tmp) / JSON_NAME
        a = committed.read_text(encoding="utf-8").splitlines(keepends=True)
        b = fresh.read_text(encoding="utf-8").splitlines(keepends=True)
        diff = list(
            difflib.unified_diff(a, b, fromfile=str(committed), tofile=str(fresh))
        )
        if not diff:
            info("No drift.")
            return 0
        sys.stdout.writelines(diff)
        return 1


# ---------------------------------------------------------------------------
# Subcommand: inspect
# ---------------------------------------------------------------------------


def cmd_inspect(args: argparse.Namespace) -> int:
    p = Path(args.path).expanduser().resolve()
    if not p.exists():
        die(f"{p} not found")
    data = rayconfig_to_json(p)
    json.dump(data, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    print()
    return 0


# ---------------------------------------------------------------------------
# README written next to the artifacts
# ---------------------------------------------------------------------------


def write_readme(out_dir: Path) -> None:
    readme = out_dir / "README.md"
    if readme.exists():
        return  # don't clobber user edits
    readme.write_text(
        """# Raycast config (non-Pro sync)

Generated by `scripts/raycast_sync.py`. See that script's docstring for the
full rationale.

## Files

- `raycast.json` — redacted, pretty-printed Raycast export (source of truth).
- `extensions.json` — installed store extensions manifest.
- `secrets.env.example` — checklist of extension API keys/tokens to re-enter
  on a fresh machine (Raycast stores these in macOS Keychain; they cannot be
  synced).

## Refresh from this machine

    just raycast-sync       # export + redact + stage

## Apply on a new machine

    just raycast-import     # reinstalls extensions, re-gzips, opens Import

## Limitations

- Extension secrets (API keys, OAuth tokens) are keychain-bound — re-enter
  per machine. `secrets.env.example` lists which ones you need.
- `raycast-enc.sqlite` (under `~/Library/Application Support/com.raycast.macos/`)
  is encrypted with a per-machine key. Do NOT try to sync it directly.
""",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="raycast_sync.py",
        description="Sync Raycast config across machines without Pro.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser("export", help="Export and redact to <dir>.")
    pe.add_argument("--out", default=str(DEFAULT_DIR))
    pe.add_argument("--auto-gui", action="store_true",
                    help="Try AppleScript GUI automation (needs Accessibility).")
    pe.add_argument("--rayconfig",
                    help="Use this existing .rayconfig instead of prompting for export.")
    pe.set_defaults(func=cmd_export)

    pr = sub.add_parser("redact", help="Re-run redaction on <dir>/raycast.json.")
    pr.add_argument("--dir", default=str(DEFAULT_DIR))
    pr.set_defaults(func=cmd_redact)

    pi = sub.add_parser("import", help="Import <dir> into Raycast.")
    pi.add_argument("--dir", default=str(DEFAULT_DIR))
    pi.add_argument("--auto-gui", action="store_true")
    pi.add_argument("--skip-extensions", action="store_true",
                    help="Don't trigger extension reinstall via deep links.")
    pi.set_defaults(func=cmd_import)

    pd = sub.add_parser("diff", help="Export fresh and diff against <dir>.")
    pd.add_argument("--dir", default=str(DEFAULT_DIR))
    pd.add_argument("--rayconfig",
                    help="Use this existing .rayconfig for the fresh side.")
    pd.set_defaults(func=cmd_diff)

    pn = sub.add_parser("inspect", help="Decompress a .rayconfig to stdout.")
    pn.add_argument("path")
    pn.set_defaults(func=cmd_inspect)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not RAYCAST_APP.exists():
        die("Raycast.app not found under /Applications. Install it first.")
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("\naborted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
