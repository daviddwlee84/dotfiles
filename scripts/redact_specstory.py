#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
Check for secrets in .specstory/history/ files using gitleaks.
Reports findings and suggests redaction format (sk-abc...xyz).

Usage:
    ./scripts/redact_specstory.py          # Check only (default)
    ./scripts/redact_specstory.py --fix    # Auto-redact and stage files
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path


def run_gitleaks_detect(target_path: str) -> list[dict]:
    """Run gitleaks and return findings as JSON."""
    result = subprocess.run(
        [
            "gitleaks",
            "detect",
            "--source",
            target_path,
            "--report-format",
            "json",
            "--report-path",
            "/dev/stdout",
            "--no-git",
            "--exit-code",
            "0",
        ],
        capture_output=True,
        text=True,
    )
    if not result.stdout.strip():
        return []
    return json.loads(result.stdout)


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


def main():
    parser = argparse.ArgumentParser(
        description="Check/redact secrets in .specstory/history/ files"
    )
    parser.add_argument(
        "--fix", action="store_true", help="Auto-redact secrets and stage files"
    )
    args = parser.parse_args()

    specstory_path = Path(".specstory/history")
    if not specstory_path.exists():
        print("No .specstory/history/ directory found")
        return 0

    # Detect secrets
    findings = run_gitleaks_detect(str(specstory_path))
    if not findings:
        print("No secrets found in .specstory/history/")
        return 0

    print(f"Found {len(findings)} potential secret(s) in .specstory/history/:\n")

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

    if args.fix:
        print("Redacting secrets...")
        modified_files = set()
        for file_path in by_file:
            path = Path(file_path)
            if path.suffix == ".md" and redact_file(path, findings):
                modified_files.add(path)

        for f in modified_files:
            subprocess.run(["git", "add", str(f)], check=True)
            print(f"  Redacted and staged: {f}")

        # Verify
        remaining = run_gitleaks_detect(str(specstory_path))
        if remaining:
            print(f"\nERROR: {len(remaining)} secrets still detected after redaction!")
            return 1

        print(f"\nSuccessfully redacted {len(modified_files)} file(s)")
        return 0
    else:
        print("Run with --fix to auto-redact these secrets")
        print("Or manually edit the files to remove sensitive information")
        return 1


if __name__ == "__main__":
    sys.exit(main())
