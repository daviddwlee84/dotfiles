#!/usr/bin/env python3
"""Install the personal CLI suite; shell startup must never call this helper.

Apply installs missing tools. Upgrade operates only on a selected, installed,
identified owner. A receipt is an installation-origin record, not a replacement
for probing the current binary (native self-updaters may have advanced it).
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


REGISTRY = Path(__file__).with_name("tools.json")
TAG = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\Z")


class InstallError(RuntimeError):
    pass


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise InstallError(f"{argv[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def digest(path):
    with open(path, "rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(handle.read()).hexdigest()


def load_tools(path=REGISTRY):
    data = json.loads(path.read_text())
    if data.get("version") != 1:
        raise InstallError("Unsupported personal tools registry version")
    seen = set()
    for tool in data["tools"]:
        if tool["id"] in seen or not TAG.fullmatch(tool["pin"]):
            raise InstallError("Invalid or duplicate personal tool registry entry")
        if tool["repo"] != "daviddwlee84/" + tool["id"]:
            raise InstallError("Registry must name an explicit first-party repository")
        seen.add(tool["id"])
    return data["tools"]


def selection(tools, mode, system, extra):
    """Missing key is legacy, not the fresh-machine prompt default."""
    result = []
    if mode == "disabled" or system not in ("Darwin", "Linux"):
        return result
    for tool in tools:
        method = None
        if mode == "enabled":
            method = "brew" if system == "Darwin" else "release"
        elif tool["id"] in ("dev-cli", "translate"):
            method = "brew" if system == "Darwin" else ("go" if extra else None)
        elif tool["id"] == "lazyclash" and extra:
            method = "go"
        if method:
            result.append({**tool, "method": method})
    return result


def read_policy():
    try:
        data = json.loads(run(["chezmoi", "data"]))
    except (OSError, ValueError, InstallError) as exc:
        raise InstallError("Cannot read chezmoi selection; pass --mode and --extra-runtimes explicitly") from exc
    mode = "legacy"
    if "installPersonalTools" in data:
        mode = "enabled" if data["installPersonalTools"] else "disabled"
    return mode, bool(data.get("installExtraRuntimes", True))


def fetch(url, destination):
    if not url.startswith("https://"):
        raise InstallError("Release downloads require HTTPS")
    request = urllib.request.Request(url, headers={"User-Agent": "dotfiles-personal-tools"})
    with urllib.request.urlopen(request, timeout=60) as response, open(destination, "wb") as output:
        limit = 256 * 1024 * 1024 if url.endswith(".tar.gz") else 2 * 1024 * 1024
        received = 0
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            received += len(chunk)
            if received > limit:
                raise InstallError("Release download exceeded its size limit")
            output.write(chunk)


def latest(tool):
    with tempfile.TemporaryDirectory(prefix="personal-release-") as tmp:
        path = Path(tmp) / "release.json"
        fetch(f"https://api.github.com/repos/{tool['repo']}/releases/latest", path)
        release = json.loads(path.read_text())
    tag = release.get("tag_name", "")
    if release.get("draft") or release.get("prerelease") or not TAG.fullmatch(tag):
        raise InstallError("Latest release is not a stable version")
    return tag


def check_version(binary, tag=None):
    output = run([str(binary), "--version"], timeout=20)
    versions = re.findall(r"(?<![\w.])v?(\d+\.\d+\.\d+)(?![\w.])", output)
    if not versions or (tag is not None and tag.removeprefix("v") not in versions):
        raise InstallError(f"Candidate version does not match {tag or 'a stable release'}")
    return "v" + versions[0]


def extract_binary(archive, name, destination):
    """Extract only the expected regular binary; never trust archive paths."""
    with tarfile.open(archive, "r:gz") as source:
        members = [member for member in source.getmembers() if member.name in (name, "./" + name)]
        if len(members) != 1 or not members[0].isfile() or members[0].size > 512 * 1024 * 1024:
            raise InstallError("Archive must contain one regular, bounded, top-level executable")
        with source.extractfile(members[0]) as content, open(destination, "wb") as output:
            shutil.copyfileobj(content, output)
    destination.chmod(0o755)


class Installer:
    def __init__(self, home=None, system=None, arch=None, completion=None):
        self.home = Path(home or Path.home())
        self.system = system or platform.system()
        machine = arch or platform.machine()
        self.arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(machine, machine)
        self.state = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local/share")) / "dotfiles/personal-tools"
        self.completion = completion

    def target(self, tool):
        return self.home / ".local/bin" / tool["binary"]

    def receipt_path(self, tool):
        return self.state / (tool["id"] + ".json")

    def receipt(self, tool):
        path = self.receipt_path(tool)
        if path.is_symlink():
            raise InstallError("Refusing a symlinked installation receipt")
        if not path.exists():
            return None
        receipt = json.loads(path.read_text())
        if receipt.get("repo") != tool["repo"] or receipt.get("binary") != tool["binary"]:
            raise InstallError("Receipt does not match the selected tool")
        return receipt

    def save_receipt(self, tool, method, binary, version, **extra):
        self.state.mkdir(parents=True, exist_ok=True)
        destination = self.receipt_path(tool)
        if destination.is_symlink():
            raise InstallError("Refusing a symlinked installation receipt")
        payload = dict(schema=1, repo=tool["repo"], binary=tool["binary"], method=method,
                       target=str(binary), version=version, sha256=digest(binary), **extra)
        fd, temporary = tempfile.mkstemp(prefix=".receipt-", dir=self.state)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(payload, output, indent=2)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)

    @contextlib.contextmanager
    def lock(self, tool):
        self.state.mkdir(parents=True, exist_ok=True)
        lock_path = self.state / (tool["id"] + ".lock")
        if lock_path.is_symlink():
            raise InstallError("Refusing a symlinked installation lock")
        with open(lock_path, "a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise InstallError("Another personal-tools operation is running") from exc
            yield

    def replace(self, tool, candidate, method, version, expected):
        """Commit binary and receipt, restoring the old binary on receipt failure."""
        target = self.target(tool)
        if target.is_symlink() or (digest(target) if target.exists() else None) != expected:
            raise InstallError("Executable changed while preparing candidate; preserving it")
        with tempfile.TemporaryDirectory(prefix=".personal-stage-", dir=target.parent) as tmp:
            tmp = Path(tmp)
            stage, backup = tmp / "candidate", tmp / "previous"
            if expected is not None:
                shutil.copy2(target, backup)
                if digest(backup) != expected:
                    raise InstallError("Executable changed while preserving rollback copy")
            shutil.copyfile(candidate, stage)
            stage.chmod(0o755)
            new_hash = digest(stage)
            if target.is_symlink() or (digest(target) if target.exists() else None) != expected:
                raise InstallError("Executable changed before replacement; preserving it")
            os.replace(stage, target)
            try:
                self.save_receipt(tool, method, target, version)
            except Exception:
                if not target.is_symlink() and target.exists() and digest(target) == new_hash:
                    if expected is None:
                        target.unlink()
                    else:
                        os.replace(backup, target)
                raise

    def active(self, tool):
        found = shutil.which(tool["binary"])
        if found:
            return Path(found)
        target = self.target(tool)
        return target if target.exists() or target.is_symlink() else None

    def go_command(self):
        mise = shutil.which("mise")
        if mise:
            try:
                found = run([mise, "which", "go"])
                if found and Path(found).is_file():
                    return found
            except InstallError:
                pass
        found = shutil.which("go")
        # An unresolved mise shim may auto-install on invocation. Ownership
        # probes and explicit upgrades must not bootstrap a missing SDK.
        if found and "/mise/shims/" not in found:
            return found
        return None

    def legacy_go(self, tool, binary):
        if binary != self.target(tool) or binary.is_symlink() or not binary.is_file():
            return False
        go = self.go_command()
        if not go:
            return False
        try:
            info = run([go, "version", "-m", str(binary)])
        except InstallError:
            return False
        module = "github.com/" + tool["repo"]
        path_matches = re.search(r"(?m)^\s*path\s+" + re.escape(tool["source"]) + r"\s*$", info)
        module_matches = re.search(r"(?m)^\s*mod\s+" + re.escape(module) + r"\s+v[^\s]+\s+h1:\S+", info)
        return bool(path_matches and module_matches and "=>" not in info and "vcs.modified=true" not in info)

    def owner(self, tool, binary):
        receipt = self.receipt(tool)
        if receipt and Path(receipt["target"]) == binary and binary.is_file() and not binary.is_symlink():
            if receipt["method"] in ("go", "release"):
                return receipt["method"]
        resolved = str(binary.resolve())
        formula = tool["formula"].rsplit("/", 1)[-1]
        if f"/Cellar/{formula}/" in resolved:
            return "brew"
        if self.legacy_go(tool, binary):
            return "go"
        return "unknown"

    def refresh(self, tool):
        if self.completion:
            run(["bash", self.completion, "--tool", tool["binary"], "--force", "--quiet"], timeout=60)

    def release(self, tool, upgrade=False):
        if self.system != "Linux" or self.arch not in ("amd64", "arm64"):
            raise InstallError("Managed releases support Linux amd64/arm64; no automatic source fallback")
        target = self.target(tool)
        before = digest(target) if target.exists() and not target.is_symlink() else None
        if target.is_symlink():
            raise InstallError("Refusing to replace a symlinked executable")
        tag = latest(tool) if upgrade else tool["pin"]
        if upgrade and check_version(target) == tag:
            return False
        asset = tool["archive"].format(repo=tool["id"], tag=tag, version=tag[1:], os="linux", arch=self.arch)
        base = f"https://github.com/{tool['repo']}/releases/download/{tag}/"
        with tempfile.TemporaryDirectory(prefix="personal-tool-") as tmp:
            tmp = Path(tmp)
            archive, checksums, candidate = tmp / asset, tmp / "checksums", tmp / tool["binary"]
            fetch(base + asset, archive)
            fetch(base + tool["checksums"], checksums)
            matches = []
            for line in checksums.read_text().splitlines():
                fields = line.split()
                if len(fields) == 2 and fields[1].lstrip("*") == asset:
                    matches.append(fields[0])
            if len(matches) != 1 or not re.fullmatch(r"[0-9a-fA-F]{64}", matches[0]) or digest(archive) != matches[0].lower():
                raise InstallError("Release checksum mismatch or missing exact archive entry")
            extract_binary(archive, tool["binary"], candidate)
            check_version(candidate, tag)
            target.parent.mkdir(parents=True, exist_ok=True)
            self.replace(tool, candidate, "release", tag, before)
        return True

    def source(self, tool, upgrade=False):
        go = self.go_command()
        if not go:
            return None  # Legacy behavior: no toolchain means no installation.
        target = self.target(tool)
        target.parent.mkdir(parents=True, exist_ok=True)
        query = "latest" if upgrade else (tool["legacy_pin"] or tool["pin"])
        with tempfile.TemporaryDirectory(prefix=".go-stage-", dir=target.parent) as stage:
            env = dict(os.environ, GOBIN=stage, GOPATH=str(self.home / ".local/share/go"), CGO_ENABLED="0")
            before = digest(target) if target.is_file() and not target.is_symlink() else None
            try:
                run([go, "install", tool["source"] + "@" + query], env=env)
            except InstallError as exc:
                # Go errors may repeat credential-bearing proxy URLs.
                raise InstallError("Go source installation failed; check the toolchain and network settings; previous executable retained") from exc
            candidate = Path(stage) / tool["binary"]
            # Old, published source pins may predate a version command; Go's
            # embedded module record is the source-channel verification.
            metadata = run([go, "version", "-m", str(candidate)])
            package_line = re.search(r"(?m)^\s*path\s+" + re.escape(tool["source"]) + r"\s*$", metadata)
            module_line = re.search(r"(?m)^\s*mod\s+github.com/" + re.escape(tool["repo"]) + r"\s+v\S+\s+h1:\S+", metadata)
            if not package_line or not module_line or "=>" in metadata:
                raise InstallError("Source candidate module does not match")
            match = re.search(r"(?m)^\s*mod\s+\S+\s+(v\S+)", metadata)
            version = match.group(1) if match else query
            self.replace(tool, candidate, "go", version, before)
        return True

    def brew(self, tool, upgrade=False):
        brew = shutil.which("brew")
        if not brew or not run([brew, "--prefix"]):
            raise InstallError("Homebrew is unavailable; the Homebrew setup role must run first")
        active = self.active(tool)
        legacy = active is not None and self.legacy_go(tool, active)
        original_hash = digest(active) if legacy else None
        installed = subprocess.run([brew, "list", "--versions", tool["formula"]], capture_output=True, text=True).stdout.strip()
        if not installed:
            if upgrade:
                return False
            run([brew, "tap", "daviddwlee84/tap"])
            run([brew, "install", "--formula", tool["formula"]])
        elif upgrade:
            run([brew, "upgrade", "--formula", tool["formula"]])
        prefix = run([brew, "--prefix", tool["formula"]])
        binary = Path(prefix) / "bin" / tool["binary"]
        version = check_version(binary)
        backup = None
        if legacy:
            if active.is_symlink() or digest(active) != original_hash:
                raise InstallError("Legacy executable changed during Brew installation; preserving it")
            backup_dir = self.state / "backups"
            backup_dir.mkdir(parents=True, exist_ok=True)
            backup = backup_dir / (tool["binary"] + "." + original_hash)
            if backup.exists() and digest(backup) != original_hash:
                raise InstallError("Unexpected content in legacy backup")
            if not backup.exists():
                shutil.copy2(active, backup)
            if digest(backup) != original_hash or digest(active) != original_hash:
                raise InstallError("Legacy backup verification failed")
            active.unlink()
        try:
            self.save_receipt(tool, "brew", binary, version, backup=str(backup) if backup else None)
        except Exception:
            if backup is not None and not active.exists() and not active.is_symlink():
                shutil.copy2(backup, active)
            raise
        return bool(not installed or upgrade or legacy)

    def execute(self, tool, action, dry_run=False):
        # Plan and absent upgrades make no directories and never bootstrap.
        if dry_run:
            return self._execute_locked(tool, action, True)
        if action == "upgrade" and self.active(tool) is None:
            return dict(changed=False, status="not-installed")
        with self.lock(tool):
            return self._execute_locked(tool, action, False)

    def _execute_locked(self, tool, action, dry_run):
        active = self.active(tool)
        owner = self.owner(tool, active) if active else None
        method = tool["method"]
        if active and owner == "unknown":
            return dict(changed=False, status="unmanaged", message="Preserved existing executable; resolve its owner explicitly")
        if action == "upgrade":
            if not active:
                return dict(changed=False, status="not-installed")
            method = owner  # Preserve the actual channel during explicit updates.
        elif active and not (method == "brew" and owner == "go"):
            return dict(changed=False, status="present", owner=owner)
        if dry_run:
            return dict(changed=False, status="planned", method=method)
        operation = {"brew": self.brew, "go": self.source, "release": self.release}[method]
        changed = operation(tool, upgrade=action == "upgrade")
        if changed:
            try:
                self.refresh(tool)
            except (OSError, InstallError, subprocess.TimeoutExpired) as exc:
                # Installation is already committed. Report that fact even
                # when the independently regenerable completion step fails.
                return dict(changed=True, status="failed", owner=method,
                            error=f"Installed successfully, but completion refresh failed: {exc}")
        return dict(changed=bool(changed), status="missing-go" if changed is None else "ok", owner=method)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "install", "upgrade"))
    parser.add_argument("--tool", help="Registry ID or executable name; omitted selects the suite")
    parser.add_argument("--mode", choices=("legacy", "enabled", "disabled"))
    parser.add_argument("--extra-runtimes", choices=("true", "false"))
    parser.add_argument("--platform", choices=("Darwin", "Linux"), default=platform.system())
    parser.add_argument("--arch", default=platform.machine())
    parser.add_argument("--completion-script")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.mode is None or args.extra_runtimes is None:
            mode, extra = read_policy()
        else:
            mode, extra = args.mode, args.extra_runtimes == "true"
        mode = args.mode or mode
        if args.extra_runtimes is not None:
            extra = args.extra_runtimes == "true"
        tools = load_tools()
        selected = selection(tools, mode, args.platform, extra)
        if args.tool:
            if not any(args.tool in (tool["id"], tool["binary"]) for tool in tools):
                raise InstallError("Unknown personal tool")
            selected = [tool for tool in selected if args.tool in (tool["id"], tool["binary"])]
        if args.action == "plan":
            print(json.dumps(selected))
            return 0
        installer = Installer(system=args.platform, arch=args.arch, completion=args.completion_script)
        results, failed = [], False
        for tool in selected:
            try:
                result = installer.execute(tool, args.action, args.dry_run)
            except (OSError, ValueError, InstallError, tarfile.TarError, subprocess.TimeoutExpired) as exc:
                result = dict(changed=False, status="failed", error=str(exc))
            failed = failed or result["status"] == "failed"
            results.append(dict(tool=tool["id"], **result))
        print(json.dumps(dict(changed=any(row["changed"] for row in results), results=results)))
        return int(failed)
    except (OSError, ValueError, InstallError) as exc:
        print(json.dumps(dict(changed=False, error=str(exc))))
        return 1


if __name__ == "__main__":
    sys.exit(main())
