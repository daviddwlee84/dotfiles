#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
Check for secrets in .specstory/history/ files using gitleaks and
detect-private-key patterns. Reports findings and suggests redaction.

Usage:
    ./scripts/redact_specstory.py              # Check staged files (default)
    ./scripts/redact_specstory.py --fix        # Auto-redact and re-stage files
    ./scripts/redact_specstory.py --working-dir  # Scan working directory instead of staged
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def run_gitleaks_staged() -> list[dict]:
    """Run gitleaks on staged files and return findings as JSON."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        report_path = f.name

    try:
        subprocess.run(
            [
                "gitleaks",
                "protect",
                "--staged",
                "--report-format",
                "json",
                "--report-path",
                report_path,
                "--exit-code",
                "0",
            ],
            capture_output=True,
            text=True,
        )
        content = Path(report_path).read_text()
        if not content.strip():
            return []
        return json.loads(content)
    except (json.JSONDecodeError, FileNotFoundError):
        return []
    finally:
        Path(report_path).unlink(missing_ok=True)


def run_gitleaks_workdir(target_path: str) -> list[dict]:
    """Run gitleaks on working directory and return findings as JSON."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        report_path = f.name

    try:
        subprocess.run(
            [
                "gitleaks",
                "detect",
                "--source",
                target_path,
                "--report-format",
                "json",
                "--report-path",
                report_path,
                "--no-git",
                "--exit-code",
                "0",
            ],
            capture_output=True,
            text=True,
        )
        content = Path(report_path).read_text()
        if not content.strip():
            return []
        return json.loads(content)
    except (json.JSONDecodeError, FileNotFoundError):
        return []
    finally:
        Path(report_path).unlink(missing_ok=True)


def redact_secret(secret: str, keep_chars: int = 3) -> str:
    """Redact secret keeping first/last N chars: sk-abc...xyz"""
    if len(secret) <= keep_chars * 2 + 3:
        return "[REDACTED]"
    return f"{secret[:keep_chars]}...{secret[-keep_chars:]}"


def redact_file(file_path: Path, findings: list[dict]) -> bool:
    """Redact secrets in a file. Returns True if modified."""
    content = file_path.read_text()
    original = content

    file_findings = [
        f for f in findings if Path(f["File"]).resolve() == file_path.resolve()
    ]

    for finding in file_findings:
        secret = finding.get("Secret", "")
        if secret and secret in content:
            content = content.replace(secret, redact_secret(secret))

    if content != original:
        file_path.write_text(content)
        return True
    return False


def filter_specstory(findings: list[dict]) -> list[dict]:
    """Filter findings to only include .specstory/history/ files."""
    return [f for f in findings if ".specstory/history/" in f.get("File", "")]


# Matches actual PEM private key blocks
_PEM_BLOCK_RE = re.compile(
    r"-----BEGIN[^-]*PRIVATE KEY[^-]*-----.*?-----END[^-]*PRIVATE KEY[^-]*-----",
    re.DOTALL,
)

# Matches the literal string the detect-private-key hook greps for
_PRIVATE_KEY_STR = "PRIVATE KEY"


def find_private_key_files(files: list[Path]) -> dict[Path, list[str]]:
    """Find files containing private key patterns. Returns {path: [match_descriptions]}."""
    results: dict[Path, list[str]] = {}
    for path in files:
        if not path.is_file() or path.suffix != ".md":
            continue
        try:
            content = path.read_text()
        except OSError:
            continue
        if _PRIVATE_KEY_STR not in content:
            continue
        matches = []
        pem_blocks = _PEM_BLOCK_RE.findall(content)
        if pem_blocks:
            matches.append(f"{len(pem_blocks)} PEM private key block(s)")
        # Count remaining mentions (outside PEM blocks)
        without_pem = _PEM_BLOCK_RE.sub("", content)
        mention_count = without_pem.count(_PRIVATE_KEY_STR)
        if mention_count:
            matches.append(f'{mention_count} "{_PRIVATE_KEY_STR}" mention(s)')
        if matches:
            results[path] = matches
    return results


def redact_private_keys(file_path: Path) -> bool:
    """Redact private key patterns in a file. Returns True if modified."""
    content = file_path.read_text()
    original = content
    # Replace full PEM blocks
    content = _PEM_BLOCK_RE.sub("[REDACTED PRIVATE KEY BLOCK]", content)
    # Replace remaining literal "PRIVATE KEY" mentions
    content = content.replace(_PRIVATE_KEY_STR, "PRIV***KEY")
    if content != original:
        file_path.write_text(content)
        return True
    return False


def main():
    parser = argparse.ArgumentParser(
        description="Check/redact secrets in .specstory/history/ files"
    )
    parser.add_argument(
        "--fix", action="store_true", help="Auto-redact secrets and re-stage files"
    )
    parser.add_argument(
        "--working-dir",
        action="store_true",
        help="Scan working directory instead of staged files (default: scan staged)",
    )
    args = parser.parse_args()

    specstory_path = Path(".specstory/history")
    if not specstory_path.exists():
        print("No .specstory/history/ directory found")
        return 0

    # --- Detect gitleaks secrets ---
    if args.working_dir:
        print("Scanning working directory...")
        findings = run_gitleaks_workdir(str(specstory_path))
    else:
        print("Scanning staged files...")
        all_findings = run_gitleaks_staged()
        findings = filter_specstory(all_findings)

    has_issues = False

    if findings:
        has_issues = True
        print(f"\nFound {len(findings)} potential secret(s) in .specstory/history/:\n")

        # Group by file
        by_file: dict[str, list[dict]] = {}
        for f in findings:
            file_path = f["File"]
            by_file.setdefault(file_path, []).append(f)

        for file_path, file_findings in by_file.items():
            print(f"  {file_path}:")
            for finding in file_findings:
                rule = finding.get("RuleID", "unknown")
                secret = finding.get("Secret", "")
                line = finding.get("StartLine", "?")
                redacted = redact_secret(secret)
                print(f"    Line {line}: [{rule}] {redacted}")
            print()
    else:
        by_file = {}

    # --- Detect private key patterns ---
    if args.working_dir:
        scan_files = list(specstory_path.glob("*.md"))
    else:
        # Get staged .specstory files
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
            capture_output=True,
            text=True,
        )
        scan_files = [
            Path(f)
            for f in result.stdout.strip().splitlines()
            if f.startswith(".specstory/history/") and f.endswith(".md")
        ]

    pk_files = find_private_key_files(scan_files)
    if pk_files:
        has_issues = True
        print(f"Found private key pattern(s) in {len(pk_files)} file(s):\n")
        for path, descriptions in pk_files.items():
            print(f"  {path}:")
            for desc in descriptions:
                print(f"    {desc}")
            print()

    if not has_issues:
        print("No secrets found in .specstory/history/")
        return 0

    if args.fix:
        print("Redacting secrets...")
        modified_files: set[Path] = set()

        # Redact gitleaks findings
        for file_path in by_file:
            path = Path(file_path)
            if path.suffix == ".md" and redact_file(path, findings):
                modified_files.add(path)

        # Redact private key patterns
        for path in pk_files:
            if redact_private_keys(path):
                modified_files.add(path)

        for f in modified_files:
            print(f"  Redacted: {f}")

        # Verify private keys
        remaining_pk = find_private_key_files(
            [Path(f) for f in modified_files if Path(f).is_file()]
        )
        if remaining_pk:
            print("ERROR: Private key patterns still detected after redaction!")
            return 1

        print(f"\nSuccessfully redacted {len(modified_files)} file(s)")
        print("Review changes with: git diff")
        print("Then stage with: git add .specstory/")
        return 0
    else:
        print("Run with --fix to auto-redact these secrets")
        print("Or manually edit the files to remove sensitive information")
        return 1


if __name__ == "__main__":
    sys.exit(main())
