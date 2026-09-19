"""Run the real Ansible role against an isolated fake SDK; no downloads or credentials.

Run: python3 -m unittest discover -s tests/unit -p test_dotnet_tools.py -v
Real SDK install/upgrade smoke instructions are in docs/tools/dotnet-tools.md.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]

# This deliberately accepts only install (never use/update), publishes a runtime
# only through exec, and rejects launching a global tool without that runtime.
MISE_STUB = r'''#!/bin/sh
set -eu
root="$HOME/.local/share/mise/installs/dotnet/10.0.203"
printf '%s\n' "$*" >> "$HOME/mise-calls"
test "$MISE_DOTNET_ISOLATED" = true
case "$*" in
  'where dotnet@10') test -d "$root"; printf '%s\n' "$root" ;;
  'install --yes dotnet@10')
    mkdir -p "$root"
    printf '#!/bin/sh\nprintf "10.0.203 [fake/sdk]\\n"\n' > "$root/dotnet"
    chmod +x "$root/dotnet"
    ;;
  'exec dotnet@10 -- dotnet tool install --global azure-cost-cli')
    mkdir -p "$HOME/.dotnet/tools"
    cat > "$HOME/.dotnet/tools/azure-cost" <<'APP'
#!/bin/sh
[ -x "$DOTNET_ROOT/dotnet" ] || exit 71
[ "$1" = --help ] || exit 72
printf 'USAGE: azure-cost\n'
APP
    chmod +x "$HOME/.dotnet/tools/azure-cost"
    ;;
  'exec dotnet@10 -- '*)
    shift 3
    export DOTNET_ROOT="$root"
    exec "$@"
    ;;
  *) exit 99 ;;
esac
'''


@unittest.skipUnless(shutil.which("ansible-playbook"), "ansible-playbook required")
class DotnetRoleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dotnet-role-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.mise = self.home / ".local/bin/mise"
        self.mise.parent.mkdir(parents=True)
        self.mise.write_text(MISE_STUB)
        self.mise.chmod(0o755)
        self.sdk = self.home / ".local/share/mise/installs/dotnet/10.0.203"
        self.tool = self.home / ".dotnet/tools/azure-cost"
        self.config = self.home / ".config/mise/config.toml"
        self.config.parent.mkdir(parents=True)
        self.config.write_text('[settings]\ndotnet.isolated = true\n[tools]\ndotnet = "10"\n')
        ansible_config = self.home / "ansible.cfg"
        ansible_config.write_text("[defaults]\ninject_facts_as_vars = False\n")
        self.env = dict(os.environ, ANSIBLE_CONFIG=str(ansible_config), ANSIBLE_NOCOLOR="1",
                        ANSIBLE_STDOUT_CALLBACK="default", ANSIBLE_LOCAL_TEMP=str(self.home / "tmp"))
        # Avoid leaking the user's environment or custom callback into subprocess output.
        self.env.pop("DOTNET_ROOT", None)
        self.env.pop("DOTNET_ROOT_ARM64", None)

    def run_role(self, *, check=False, old_el=False):
        play = [{"hosts": "localhost", "connection": "local", "gather_facts": False,
                 "environment": {"HOME": str(self.home)},
                 "vars": {"ansible_facts": {"env": {"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                                             "os_family": "Debian", "architecture": "aarch64"},
                          "oldEL": old_el},
                 "roles": [str(REPO / "dot_ansible/roles/dotnet_tools")]}]
        play_file = self.home / "play.json"
        play_file.write_text(json.dumps(play))
        argv = ["ansible-playbook", "-i", "localhost,", "--skip-tags", "sudo", str(play_file)]
        if check:
            argv.append("--check")
        result = subprocess.run(argv, env=self.env, text=True, capture_output=True, timeout=90)
        result.output = result.stdout + result.stderr
        return result

    def seed_sdk(self, healthy=True):
        self.sdk.mkdir(parents=True)
        exe = self.sdk / "dotnet"
        exe.write_text('#!/bin/sh\necho "10.0.203 [fake/sdk]"\n' if healthy else '#!/bin/sh\nexit 7\n')
        exe.chmod(0o755)

    def test_empty_parent_installs_and_second_apply_is_unchanged(self):
        self.sdk.parent.mkdir(parents=True)
        before = self.config.read_bytes()
        first = self.run_role()
        self.assertEqual(first.returncode, 0, first.output)
        self.assertTrue(self.tool.is_file())
        second = self.run_role()
        self.assertEqual(second.returncode, 0, second.output)
        self.assertRegex(second.output, r"changed=0\s")
        calls = (self.home / "mise-calls").read_text()
        self.assertEqual(calls.count("install --yes"), 1)
        self.assertEqual(calls.count("tool install --global"), 1)
        self.assertEqual(calls.count(str(self.tool) + " --help"), 2)
        self.assertEqual(self.config.read_bytes(), before)

    def test_existing_version_directory_is_reused(self):
        self.seed_sdk()
        result = self.run_role()
        self.assertEqual(result.returncode, 0, result.output)
        self.assertNotIn("install --yes", (self.home / "mise-calls").read_text())

    def test_broken_sdk_fails_without_installing_or_using_system_dotnet(self):
        self.seed_sdk(healthy=False)
        result = self.run_role()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Verify the selected .NET SDK can run", result.output)
        self.assertFalse(self.tool.exists())
        self.assertNotIn("install --yes", (self.home / "mise-calls").read_text())

    def test_existing_broken_tool_is_not_treated_as_success(self):
        self.seed_sdk()
        self.tool.parent.mkdir(parents=True)
        self.tool.write_text('#!/bin/sh\necho "You must install .NET to run this application." >&2\nexit 73\n')
        self.tool.chmod(0o755)
        result = self.run_role()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("You must install .NET", result.output)
        self.assertNotIn("tool install", (self.home / "mise-calls").read_text())

    def test_fresh_check_mode_does_not_install(self):
        result = self.run_role(check=True)
        self.assertEqual(result.returncode, 0, result.output)
        self.assertFalse(self.sdk.exists())
        self.assertFalse(self.tool.exists())

    def test_old_el_does_not_attempt_install(self):
        result = self.run_role(old_el=True)
        self.assertEqual(result.returncode, 0, result.output)
        self.assertFalse((self.home / "mise-calls").exists())


@unittest.skipUnless(shutil.which("chezmoi"), "chezmoi required")
class DotnetTemplateTest(unittest.TestCase):
    def test_opt_in_and_opt_out_across_platforms(self):
        template = (REPO / "dot_config/mise/config.toml.tmpl").read_text()
        for platform, release in [("darwin", {}), ("linux", {"id": "ubuntu", "versionID": "24.04"}),
                                  ("linux", {"id": "centos", "versionID": "7"})]:
            for enabled in (True, False):
                with self.subTest(platform=platform, release=release, enabled=enabled):
                    data = {"installDotnetTools": enabled, "installExtraRuntimes": False,
                            "chezmoi": {"os": platform, "osRelease": release}}
                    result = subprocess.run(["chezmoi", "execute-template", "--override-data", json.dumps(data)],
                                            input=template, text=True, capture_output=True, check=True)
                    expected = enabled and release.get("id") != "centos"
                    self.assertEqual('dotnet = "10"' in result.stdout, expected)
                    self.assertEqual('dotnet.isolated = true' in result.stdout, expected)


if __name__ == "__main__":
    unittest.main()
