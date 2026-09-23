"""Guardrails for the tool catalog SSOT (dot_config/docs/tools/tool-catalog.toml).

The catalog feeds `tv inventory` and generates the Tool index in
docs/this_repo/tool-managers.md. These tests keep it honest against the real
install sources (role defaults, the devtools brew list, Brewfiles) so a tool
added to a role but not to the catalog fails CI instead of silently vanishing
from the inventory.

Run: python3 -m unittest discover -s tests/unit -p test_tool_catalog.py -v
"""

import importlib.util
import re
import subprocess
import sys
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "dot_config/docs/tools/tool-catalog.toml"
HELPER = REPO / "dot_config/television/executable_tool-catalog.py"
ROLES_DIR = REPO / "dot_ansible/roles"
ANSIBLE_RUN = REPO / ".chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl"

REQUIRED = {"id", "category", "desc", "role", "mac", "linux"}
ALLOWED = REQUIRED | {
    "label", "bins", "pkgs", "role_linux", "tag", "gate", "gate_linux",
    "app", "docs", "upgrade", "role_md",
}
# Role-defaults lists whose `binary:` / `extra_binaries:` must all be catalogued.
ROLE_TOOL_LISTS = [
    "python_uv_tools", "llm_tools", "js_cli_tools", "ruby_gem_tools",
    "dotnet_tools", "go_tools", "rust_cargo_tools",
]


def load_helper():
    spec = importlib.util.spec_from_file_location("tool_catalog", HELPER)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["tool_catalog"] = mod
    spec.loader.exec_module(mod)
    return mod


tc = load_helper()


def load_catalog():
    with open(CATALOG, "rb") as fh:
        return tomllib.load(fh)


def covered_names(cat):
    names = set()
    for t in cat["tool"]:
        names.add(t["id"].lower())
        names.update(b.lower() for b in tc.bins_of(t))
        names.update(p.lower() for p in t.get("pkgs", []))
    return names


def prompt_keys():
    src = (REPO / "scripts/init/dotfiles_init.py").read_text()
    return set(re.findall(r'Prompt\("([A-Za-z]+)"', src))


def gate_keys(expr):
    for term in filter(None, (s.strip() for s in expr.split("&"))):
        yield term.lstrip("!").split("=", 1)[0]


class SchemaTest(unittest.TestCase):
    def setUp(self):
        self.cat = load_catalog()

    def test_fields_and_uniqueness(self):
        seen = set()
        cats = set(self.cat["categories"])
        roles = self.cat["roles"]
        for t in self.cat["tool"]:
            with self.subTest(tool=t.get("id")):
                self.assertTrue(REQUIRED <= t.keys(), f"missing {REQUIRED - t.keys()}")
                self.assertTrue(t.keys() <= ALLOWED, f"unknown {t.keys() - ALLOWED}")
                self.assertNotIn(t["id"], seen, "duplicate id")
                seen.add(t["id"])
                self.assertIn(t["category"], cats)
                self.assertIn(t["role"], roles)
                if "role_linux" in t:
                    self.assertIn(t["role_linux"], roles)
                self.assertNotIn("\t", t["desc"])
                if "docs" in t:
                    self.assertTrue((REPO / t["docs"]).is_file(), t["docs"])

    def test_roles_exist(self):
        for name, role in self.cat["roles"].items():
            if "install" in role:  # pseudo-role (Brewfile, mise, bootstrap, …)
                continue
            with self.subTest(role=name):
                self.assertTrue((ROLES_DIR / name).is_dir(), f"no ansible role {name}")

    def test_gate_keys_are_real_prompts(self):
        keys = prompt_keys()
        exprs = [r.get("gate", "") for r in self.cat["roles"].values()]
        for t in self.cat["tool"]:
            exprs += [t.get("gate", ""), t.get("gate_linux", "")]
        exprs += list(self.cat.get("gate_defaults", {}))
        for expr in exprs:
            for key in gate_keys(expr):
                with self.subTest(key=key):
                    self.assertIn(key, keys, "gate names an unknown chezmoi prompt")

    def test_role_gates_mirror_ansible_run_script(self):
        """`[roles.X] gate` must match the `{{ if $key }}` that adds X's tag."""
        script = ANSIBLE_RUN.read_text().splitlines()
        for name, role in self.cat["roles"].items():
            gate = role.get("gate", "")
            if "install" in role or not gate or "=" in gate or "&" in gate:
                continue
            if name == "personal_tools":  # tri-state PERSONAL_TOOLS_MODE, not a TAGS toggle
                continue
            tag = role.get("tag", name)
            idx = next(
                (i for i, l in enumerate(script) if f'TAGS="${{TAGS}},{tag}"' in l), None
            )
            if idx is None:  # always-on tag (only removed when the gate is off)
                removal = any(f'TAGS="${{TAGS//,{tag}/}}"' in l for l in script)
                with self.subTest(role=name):
                    self.assertTrue(removal, f"tag {tag} not found in run script")
                continue
            with self.subTest(role=name):
                window = "\n".join(script[max(0, idx - 3):idx])
                self.assertIn(gate, window, f"{tag} is gated by something else")


class CoverageTest(unittest.TestCase):
    """Every tool an install source names must have a catalog entry."""

    def setUp(self):
        self.names = covered_names(load_catalog())

    def assertCovered(self, name, source):
        self.assertTrue(name.lower() in self.names, f"{name} ({source}) missing from tool-catalog.toml")

    def test_role_default_binaries(self):
        for role in ROLE_TOOL_LISTS:
            text = (ROLES_DIR / role / "defaults/main.yml").read_text()
            bins = re.findall(r"^\s+binary:\s*([\w.+-]+)", text, re.M)
            for block in re.findall(r"extra_binaries:\n((?:\s+- .*\n)+)", text):
                bins += re.findall(r"^\s+-\s+([\w.+-]+)", block, re.M)
            for b in bins:
                with self.subTest(role=role, binary=b):
                    self.assertCovered(b, role)

    def test_devtools_macos_brew_list(self):
        text = (ROLES_DIR / "devtools/tasks/main.yml").read_text()
        m = re.search(
            r"- name: Install developer CLI tools \(macOS\)\n.*?\n    name:\n(.*?)\n(?:- name:|\n)",
            text, re.S,
        )
        self.assertIsNotNone(m, "devtools macOS brew block moved — update this test")
        pkgs = re.findall(r"^\s+- ([a-z0-9][\w.+-]*)\s*$", m.group(1), re.M)
        self.assertGreater(len(pkgs), 30)
        for p in pkgs:
            with self.subTest(formula=p):
                self.assertCovered(p, "devtools brew")

    def test_brewfiles(self):
        for f in ("Brewfile.tmpl", "Brewfile.darwin.tmpl", "Brewfile.linux.tmpl"):
            path = REPO / "dot_config/homebrew" / f
            if not path.exists():
                continue
            for kind, name in re.findall(r'^\s*(cask|brew) "([^"]+)"', path.read_text(), re.M):
                name = name.rsplit("/", 1)[-1]
                with self.subTest(file=f, pkg=name):
                    self.assertCovered(name, f)


class GeneratedIndexTest(unittest.TestCase):
    def test_tool_index_in_sync(self):
        region = tc.render_region(load_catalog())
        for doc in ("tool-managers.md", "tool-managers.zh-TW.md"):
            with self.subTest(doc=doc):
                text = (REPO / "docs/this_repo" / doc).read_text()
                self.assertEqual(tc.splice(text, region), text, "run `just gen-tool-index`")


class DerivationTest(unittest.TestCase):
    def setUp(self):
        self.cat = load_catalog()
        self.roles = self.cat["roles"]

    def tool(self, tool_id):
        return tc.find_tool(self.cat, tool_id)

    def test_eval_gate(self):
        d = {"installMediaTools": True, "profile": "ubuntu_desktop", "agentSounds": "peon"}
        self.assertTrue(tc.eval_gate("", {}, {}))
        self.assertTrue(tc.eval_gate("installMediaTools", d, {}))
        self.assertFalse(tc.eval_gate("installIacTools", d, {}))
        self.assertTrue(tc.eval_gate("installExtraRuntimes", {}, {"installExtraRuntimes": True}))
        self.assertTrue(tc.eval_gate("profile=ubuntu_desktop", d, {}))
        self.assertFalse(tc.eval_gate("installNiri&profile=ubuntu_desktop", d, {}))
        self.assertTrue(tc.eval_gate("!installNiri", d, {}))
        self.assertTrue(tc.eval_gate("agentSounds=peon", d, {}))

    def test_os_applicability(self):
        self.assertFalse(tc.applies_to_os(self.tool("ethtool"), self.roles, "darwin"))
        self.assertTrue(tc.applies_to_os(self.tool("ethtool"), self.roles, "linux"))
        self.assertFalse(tc.applies_to_os(self.tool("aerospace"), self.roles, "linux"))
        # "same" on Linux means the macOS method applies too.
        self.assertTrue(tc.applies_to_os(self.tool("apprise"), self.roles, "linux"))

    def test_per_os_role_and_gate(self):
        ts = self.tool("tailscale")
        self.assertEqual(tc.gate_for(ts, self.roles, "darwin"), "installBrewApps")
        self.assertEqual(tc.gate_for(ts, self.roles, "linux"), "installTailscale")
        self.assertEqual(tc.install_cmd(ts, self.roles, "linux"), "just ansible-tags tailscale")

    def test_install_and_upgrade(self):
        self.assertEqual(tc.install_cmd(self.tool("ffmpeg"), self.roles, "darwin"),
                         "just ansible-tags media_tools")
        self.assertEqual(tc.install_cmd(self.tool("copyq"), self.roles, "linux"),
                         "just ansible-tags gui_apps")
        self.assertEqual(tc.upgrade_cmd(self.tool("visidata"), "darwin"), "just upgrade-uv")
        self.assertEqual(tc.upgrade_cmd(self.tool("herdr"), "linux"), "just upgrade-herdr")
        self.assertEqual(tc.upgrade_cmd(self.tool("lazyclash"), "darwin"), "just upgrade-personal")


class CliSmokeTest(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run(
            [sys.executable, str(HELPER), "--catalog", str(CATALOG), *args],
            capture_output=True, text=True, timeout=60,
        )

    def test_source_rows_have_seven_columns(self):
        r = self.run_helper("source")
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = r.stdout.splitlines()
        self.assertEqual(len(rows), len(load_catalog()["tool"]))
        for row in rows:
            self.assertEqual(len(row.split("\t")), 7, row)

    def test_preview_and_cmd(self):
        r = self.run_helper("preview", "ripgrep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Fast regex search", r.stdout)
        r = self.run_helper("cmd", "ripgrep", "install")
        self.assertEqual(r.stdout.strip(), "just ansible-tags base")


if __name__ == "__main__":
    unittest.main()
