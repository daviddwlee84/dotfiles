#!/usr/bin/env python3
"""Browser provisioning shared by Ansible, apply freshness checks and upgrades.

Standard library only; runs with Python 3.8+. This is an internal repository
helper, not a deployed user CLI. No editor configuration or browser sessions
are changed by skill synchronization.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile


def data_home():
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))


def state_home():
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "dotfiles/browser-tools"


def run(argv, *, env=None, check=True):
    result = subprocess.run([str(x) for x in argv], text=True, capture_output=True,
                            env=env, timeout=600)
    if check and result.returncode:
        raise RuntimeError("{}: {}".format(shlex.join([str(x) for x in argv]),
                                         (result.stderr or result.stdout).strip()))
    return result


def atomic_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        out.write(text)
        temp = Path(out.name)
    temp.replace(path)


def terminal_root():
    command = shutil.which("terminal-browser")
    if not command:
        command = str(Path(os.environ.get("XDG_BIN_HOME", str(Path.home() / ".local/bin"))) / "terminal-browser")
    binary = Path(command).resolve()
    # Homebrew and our Linux launcher are symlinks into the distribution.
    candidate = binary.parent.parent
    if (candidate / "skills/manifest").is_file():
        return candidate
    # The upstream curl installer writes a small shell launcher instead.
    candidate = data_home() / "terminal-browser/app"
    if (candidate / "skills/manifest").is_file() and Path(command).is_file():
        return candidate.resolve()
    return None


def node_environment():
    env = dict(os.environ, CI="1", NO_UPDATE_NOTIFIER="1")
    mise = shutil.which("mise") or str(Path.home() / ".local/bin/mise")
    if Path(mise).is_file():
        result = run([mise, "which", "node"], check=False)
        if result.returncode == 0 and Path(result.stdout.strip()).is_file():
            env["PATH"] = str(Path(result.stdout.strip()).parent) + os.pathsep + env.get("PATH", "")
    return env


def playwright_package(env):
    command = shutil.which("playwright-cli", path=env.get("PATH"))
    if not command:
        return None
    for parent in Path(command).resolve().parents:
        manifest = parent / "package.json"
        if manifest.is_file() and json.loads(manifest.read_text()).get("name") == "@playwright/cli":
            return parent
    return None


def core_paths(package, env):
    # Resolve dependencies from the CLI package, never from the user's project.
    script = """const {createRequire}=require('module');
const r=createRequire(process.argv[1]+'/package.json');
const path=require('path');
console.log(JSON.stringify({core:path.dirname(r.resolve('playwright-core/package.json')),
browser:r('playwright').chromium.executablePath()}));"""
    return json.loads(run(["node", "-e", script, package], env=env).stdout)


def safe_link(source, destination, old_links):
    """Only replace our recorded links or links to a packaged skill of this tool."""
    source = source.resolve()
    skill = source.name
    if not (source / "SKILL.md").is_file():
        raise RuntimeError("Missing packaged skill: " + str(source))
    if destination.is_symlink():
        old = os.readlink(destination)
        if destination.resolve() == source:
            return False
        # Recognize the official pre-existing cask/curl links, not an arbitrary
        # custom checkout with "terminal-browser/skills" somewhere in its path.
        packaged = skill == "terminal-browser" and (
            re.fullmatch(r".*/Caskroom/terminal-browser/[^/]+/terminal-browser/skills/(default|codex)/terminal-browser", old)
            or re.fullmatch(re.escape(str(data_home() / "terminal-browser"))
                            + r"/(app|releases/v[\d.]+)/skills/(default|codex)/terminal-browser", old))
        if old_links.get(str(destination)) != old and not packaged:
            print("SKIP: preserving custom skill link " + str(destination))
            return False
    elif destination.exists():
        print("SKIP: preserving custom skill directory " + str(destination))
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as staging:
        link = Path(staging) / "link"
        link.symlink_to(source, target_is_directory=True)
        link.replace(destination)
    print("CHANGED: skill " + str(destination))
    return True


def sync_skills(env, *, terminal=True, playwright=True):
    receipt = state_home() / "skill-links.json"
    old_links = json.loads(receipt.read_text()) if receipt.exists() else {}
    links = dict(old_links)
    pairs = []
    root = terminal_root() if terminal else None
    if root:
        manifest = [line.split() for line in (root / "skills/manifest").read_text().splitlines()]
        # Only this tool; do not start installing unrelated future manifest entries.
        pairs.append((root / "skills/default/terminal-browser",
                      Path.home() / ".agents/skills/terminal-browser"))
        for row in manifest:
            if len(row) >= 3 and row[0] == "agent":
                location = Path(row[2])
                variant = row[3] if len(row) > 3 else "default"
                if location.is_absolute() or ".." in location.parts or not re.fullmatch(r"[\w-]+", variant):
                    raise RuntimeError("Invalid bundled skill manifest entry")
                destination = Path.home() / location
                if destination.parent.exists():
                    pairs.append((root / "skills" / variant / "terminal-browser", destination / "terminal-browser"))
    package = playwright_package(env) if playwright else None
    if package:
        source = Path(core_paths(package, env)["core"]) / "lib/tools/skills/playwright-cli"
        for target in (".agents", ".claude", ".codex", ".cursor", ".gemini"):
            if target == ".agents" or (Path.home() / target).exists():
                pairs.append((source, Path.home() / target / "skills/playwright-cli"))
    for source, destination in pairs:
        safe_link(source, destination, old_links)
        if destination.is_symlink() and destination.resolve() == source.resolve():
            links[str(destination)] = os.readlink(destination)
    if links != old_links:
        atomic_text(receipt, json.dumps(links, indent=2) + "\n")


def macos_major():
    # Some Homebrew Python builds return an empty platform.mac_ver() on newer
    # macOS releases; sw_vers is authoritative.
    release = platform.mac_ver()[0]
    if not release:
        try:
            release = subprocess.run(["/usr/bin/sw_vers", "-productVersion"], capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            release = ""
    try:
        return int(release.split(".")[0])
    except ValueError:
        return 0


def browser_supported():
    if platform.machine() not in ("arm64", "aarch64", "x86_64", "amd64"):
        return False
    if sys.platform == "darwin":
        return macos_major() >= 14
    if sys.platform != "linux":
        return False
    values = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip('"')
    version = tuple(int(x) for x in values.get("VERSION_ID", "0").split("."))
    return ((values.get("ID") == "ubuntu" and version >= (22, 4)) or
            (values.get("ID") == "debian" and version >= (12,)))


def install_playwright(env):
    package = playwright_package(env)
    if package:
        run(["playwright-cli", "--version"], env=env)
        return
    if shutil.which("playwright-cli", path=env.get("PATH")):
        raise RuntimeError("Existing playwright-cli has an unknown package layout; preserving it")
    if not shutil.which("npm", path=env.get("PATH")):
        raise RuntimeError("Node/npm unavailable; provision lazyvim_deps first")
    run(["npm", "install", "-g", "@playwright/cli"], env=env)
    run(["playwright-cli", "--version"], env=env)
    print("CHANGED: installed @playwright/cli")


def refresh_playwright(env):
    package = playwright_package(env)
    if not package:
        return
    if not browser_supported():
        print("SKIP: Chromium provisioning requires macOS 14+ or Debian 12+/Ubuntu 22.04+, x64/arm64")
        return
    paths = core_paths(package, env)
    stamp = state_home() / "chromium-ready.json"
    wanted = {"package": str(package), "version": json.loads((package / "package.json").read_text())["version"],
              "browser": paths["browser"]}
    if Path(paths["browser"]).is_file() and stamp.exists() and json.loads(stamp.read_text()) == wanted:
        return
    run(["playwright-cli", "install-browser", "chromium"], env=env)
    # Actually launch the selected runtime: files on disk do not prove missing
    # shared libraries, sandbox restrictions, or a broken download are absent.
    script = """const {createRequire}=require('module');
const r=createRequire(process.argv[1]+'/package.json');
(async()=>{const b=await r('playwright').chromium.launch({headless:true});
try {const p=await b.newPage(); await p.setContent('<title>browser-tools smoke</title>');
if(await p.title()!=='browser-tools smoke') throw Error('unexpected page');}
finally {await b.close();}})().catch(e=>{console.error(e);process.exit(1)});"""
    run(["node", "-e", script, package], env=env)
    atomic_text(stamp, json.dumps(wanted, sort_keys=True) + "\n")
    print("CHANGED: matching Chromium installed and launch verified")


def sandbox_paths():
    root = terminal_root()
    if not root:
        return
    for name in ("pixel", "electron"):
        binary = root / "electron" / name
        if binary.is_file():
            print(json.dumps([str(root / "scripts/apparmor.sh"), str(binary)]))
            return
    raise RuntimeError("Cannot locate packaged Linux Electron executable")


def terminal_busy():
    # Avoid `ls`: upstream automatically runs editor setup on most CLI commands.
    # A running Electron or renderer is enough to defer a bulk upgrade, including
    # when its instance registry is stale or the active terminal is unsupported.
    result = run(["ps", "-axo", "args="], check=False)
    if result.returncode:
        raise RuntimeError("Cannot determine active browsers; leaving installation untouched")
    return any("terminal-browser" in line and
               ("/electron/" in line or "/browser/dist/" in line)
               for line in result.stdout.splitlines())


def extract_release(archive, destination):
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        for member in members:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or member.isdev() or member.isfifo():
                raise RuntimeError("Unsafe release archive member")
            if member.issym() or member.islnk():
                target = path.parent / member.linkname if member.issym() else Path(member.linkname)
                resolved = (destination / target).resolve()
                if destination.resolve() not in resolved.parents:
                    raise RuntimeError("Unsafe release archive link")
        # Releases come from the official manifest and must match its SHA-256.
        if hasattr(tarfile, "data_filter"):
            bundle.extractall(destination, filter="data")
        else:
            bundle.extractall(destination)


def install_terminal_browser(upgrade=False):
    if sys.platform != "linux" or not browser_supported():
        print("SKIP: release installer supports modern Debian/Ubuntu x64/arm64; use Homebrew on macOS")
        return
    base = data_home() / "terminal-browser"
    launcher = Path(os.environ.get("XDG_BIN_HOME", str(Path.home() / ".local/bin"))) / "terminal-browser"
    receipt = state_home() / "terminal-release.json"
    if not upgrade and (shutil.which("terminal-browser") or launcher.exists()):
        return
    if upgrade:
        if not receipt.exists() or not launcher.is_symlink() or terminal_root() != launcher.resolve().parent.parent:
            print("SKIP: no active repo-managed release; use this installation's package manager")
            return
        if terminal_busy():
            print("SKIP: terminal-browser is running; close its browsers before upgrading")
            return
    raw = run(["curl", "-fsSL", "--retry", "2", "--max-time", "45",
               "https://terminal-browser.sh/install/latest.json"]).stdout
    manifest = json.loads(raw)
    version = manifest["version"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise RuntimeError("Invalid stable version in release manifest")
    if upgrade and json.loads(receipt.read_text()).get("version") == version:
        return
    arch = "arm64" if platform.machine() in ("aarch64", "arm64") else "x64"
    asset = manifest["platforms"]["linux-" + arch]
    if not asset["url"].startswith("https://terminal-browser.sh/install/dl/"):
        raise RuntimeError("Unexpected release download origin")
    base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=base) as work:
        work = Path(work)
        archive = work / "release.tgz"
        run(["curl", "-fL", "--retry", "2", "--connect-timeout", "20", "--max-time", "300",
             asset["url"], "-o", archive])
        with archive.open("rb") as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != asset["sha256"]:
            raise RuntimeError("terminal-browser checksum mismatch; installation unchanged")
        unpack = work / "unpack"
        unpack.mkdir()
        extract_release(archive, unpack)
        roots = [p for p in unpack.iterdir() if (p / "bin/terminal-browser").is_file()]
        if len(roots) != 1:
            raise RuntimeError("Unexpected release layout")
        candidate = roots[0]
        run([candidate / "bin/terminal-browser", "--version"])
        # Atomic launcher replacement; retain the previous version for rollback.
        releases = base / "releases"
        releases.mkdir(exist_ok=True)
        target = releases / version
        if target.exists():
            raise RuntimeError("Release directory already exists without a matching receipt: " + str(target))
        candidate.rename(target)
        launcher.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=launcher.parent) as staging:
            staged = Path(staging) / "terminal-browser"
            staged.symlink_to(target / "bin/terminal-browser")
            staged.replace(launcher)
        atomic_text(receipt, json.dumps({"version": version, "target": str(target)}) + "\n")
    print("CHANGED: installed terminal-browser " + version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install-terminal-browser", "install-playwright", "sync", "refresh", "refresh-playwright", "sandbox-paths"))
    parser.add_argument("--upgrade", action="store_true")
    parser.add_argument("--skip-terminal", action="store_true")
    parser.add_argument("--skip-playwright", action="store_true")
    parser.add_argument("--preload-chromium", action="store_true",
                        help="Opt in to downloading/repairing Chromium; refresh otherwise only synchronizes skills")
    args = parser.parse_args()
    if args.command == "install-terminal-browser":
        install_terminal_browser(args.upgrade)
        return
    if args.command == "sandbox-paths":
        sandbox_paths()
        return
    env = node_environment()
    if args.command == "install-playwright":
        install_playwright(env)
    else:
        sync_skills(env, terminal=not args.skip_terminal, playwright=not args.skip_playwright)
        if args.command in ("refresh", "refresh-playwright") and args.preload_chromium and not args.skip_playwright:
            refresh_playwright(env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print("browser-tools: " + str(error), file=sys.stderr)
        sys.exit(1)
