"""Download and validate .NET in a disposable HOME (run inside a Linux container).

Requires: mise, chezmoi, ansible-playbook, bash, zsh, Python 3, root/sudo,
and access to Microsoft's SDK downloads and NuGet. Run from any directory:
    python3 tests/smoke/dotnet_install.py
No Azure credentials required. Host HOME and installed SDKs are never reused.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]


def main():
    binaries = {name: shutil.which(name) for name in ("mise", "chezmoi", "ansible-playbook", "bash", "zsh")}
    assert all(binaries.values()), f"Missing prerequisites: {binaries}"
    with tempfile.TemporaryDirectory(prefix="dotnet-fresh-") as temp:
        root = Path(temp)
        home = root / "home"
        home.mkdir()
        source = root / "source"
        for relative in ("dot_config/mise/config.toml.tmpl", "dot_config/shell/00_exports.sh.tmpl",
                         "dot_config/shell/05_mise.sh"):
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        mise = home / ".local/bin/mise"
        mise.parent.mkdir(parents=True)
        shutil.copy2(binaries["mise"], mise)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("MISE_", "DOTNET_", "XDG_", "ANSIBLE_", "__MISE"))}
        env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   PATH=f"{mise.parent}:{os.environ['PATH']}",
                   DOTNET_CLI_TELEMETRY_OPTOUT="1", MISE_AUTO_INSTALL="false")
        config = root / "chezmoi.json"
        config.write_text(json.dumps({"data": {"profile": "ubuntu_server", "installDotnetTools": True,
                                               "installExtraRuntimes": False, "useChineseMirror": False}}))

        def run(argv):
            result = subprocess.run(argv, cwd=home, env=env, text=True, capture_output=True, timeout=1200)
            print(result.stdout, end="", flush=True)
            if result.stderr:
                print(result.stderr, end="", flush=True)
            result.check_returncode()
            return result.stdout

        run([binaries["chezmoi"], "--source", str(source), "--destination", str(home),
             "--config", str(config), "--persistent-state", str(root / "state.db"), "apply"])
        managed_config = home / ".config/mise/config.toml"
        before = hashlib.sha256(managed_config.read_bytes()).digest()
        ansible_config = root / "ansible.cfg"
        ansible_config.write_text("[defaults]\ninject_facts_as_vars = False\n")
        env["ANSIBLE_CONFIG"] = str(ansible_config)
        play = root / "play.json"
        play.write_text(json.dumps([{"hosts": "localhost", "connection": "local", "gather_facts": True,
                                     "roles": [str(REPO / "dot_ansible/roles/dotnet_tools")]}]))
        argv = [binaries["ansible-playbook"], "-i", "localhost,", str(play)]
        run(argv)
        repeated = run(argv)
        assert "changed=0 " in repeated, "Second apply must not reinstall or upgrade"
        assert hashlib.sha256(managed_config.read_bytes()).digest() == before, "Role rewrote managed config"
        for shell in ("bash", "zsh"):
            flags = ["--noprofile", "--norc"] if shell == "bash" else ["-f"]
            run([binaries[shell], *flags, "-ic",
                 'source "$HOME/.config/shell/00_exports.sh"; '
                 'source "$HOME/.config/shell/05_mise.sh"; _mise_hook; '
                 'test -x "$DOTNET_ROOT/dotnet" && azure-cost --help >/dev/null'])
        run([str(mise), "exec", "--", "dotnet", "--list-sdks"])
        print("PASS: fresh install, unchanged second apply, preserved config, Bash and Zsh apphost startup.")


if __name__ == "__main__":
    main()
