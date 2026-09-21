"""Opt-in public-asset acceptance on disposable GitHub-hosted runners only.

Runs only the personal_tools role with a temporary HOME. macOS deliberately
uses the runner's Homebrew prefix; this must never run on a user's workstation.
"""
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "personal_tools", ROOT / "dot_ansible/roles/personal_tools/files/personal_tools.py"
)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def main():
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("PERSONAL_TOOLS_LIVE") == "1"):
        raise SystemExit("Live installation requires explicit opt-in on a GitHub-hosted runner")
    system = platform.system()
    if system not in ("Darwin", "Linux"):
        raise SystemExit("Unsupported smoke-test platform")
    with tempfile.TemporaryDirectory(prefix="personal-live-") as temporary:
        home = Path(temporary).resolve()
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   XDG_DATA_HOME=str(home / ".local/share"), XDG_CACHE_HOME=str(home / ".cache"),
                   XDG_STATE_HOME=str(home / ".local/state"),
                   PATH=str(home / ".local/bin") + os.pathsep + os.environ["PATH"],
                   ANSIBLE_CONFIG=str(home / "ansible.cfg"), ANSIBLE_NOCOLOR="1",
                   ANSIBLE_LOCAL_TEMP=str(home / "ansible-local"),
                   ANSIBLE_REMOTE_TEMP=str(home / "ansible-remote"))
        (home / "ansible.cfg").write_text(
            "[defaults]\nroles_path = " + str(ROOT / "dot_ansible/roles") + "\n"
        )
        play = [{"hosts": "localhost", "gather_facts": True,
                 "vars": {"ansible_python_interpreter": sys.executable,
                          "personal_tools_mode": "enabled",
                          "personal_tools_extra_runtimes": False,
                          "personal_tools_completion_script": str(ROOT / "scripts/generate_completions.sh")},
                 "roles": ["personal_tools"]}]
        playbook = home / "play.json"
        playbook.write_text(json.dumps(play))
        for iteration, expected in enumerate((1, 0), start=1):
            result = subprocess.run(
                ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
                env=env, capture_output=True, text=True, timeout=900,
            )
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            if result.returncode or not re.search(r"changed=" + str(expected) + r"\b", result.stdout):
                raise RuntimeError(f"Apply {iteration} failed or was not idempotent")
        for tool in installer.load_tools():
            receipt_path = home / ".local/share/dotfiles/personal-tools" / (tool["id"] + ".json")
            receipt = json.loads(receipt_path.read_text())
            binary = Path(receipt["target"])
            expected_method = "brew" if system == "Darwin" else "release"
            if receipt["method"] != expected_method or receipt["sha256"] != installer.digest(binary):
                raise RuntimeError(f"Wrong installation receipt: {tool['id']}")
            version = subprocess.run([str(binary), "--version"], env=env, capture_output=True,
                                     text=True, check=True, timeout=30).stdout.strip()
            if system == "Linux" and tool["pin"][1:] not in version:
                raise RuntimeError(f"Wrong pinned version: {tool['id']}")
            for completion in (home / ".zfunc" / ("_" + tool["binary"]),
                               home / ".local/share/bash-completion/completions" / tool["binary"]):
                if not completion.is_file() or completion.stat().st_size == 0:
                    raise RuntimeError(f"Missing completion: {completion}")
            print(f"Verified {tool['id']}: {version} ({expected_method})")


if __name__ == "__main__":
    main()
