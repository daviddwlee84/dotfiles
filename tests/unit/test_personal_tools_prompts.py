"""Run with the same rich/questionary/tyro dependencies as the init wrapper."""
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("personal_tools_init_fixture", ROOT / "scripts/init/dotfiles_init.py")
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)


class PromptTests(unittest.TestCase):
    def setUp(self):
        self.pf = m.Preflight("/fixture/chezmoi", "/fixture/git", None, True, "darwin", "arm64", False)

    def test_full_and_lean_bundles(self):
        for name, expected in (("personal-mac", True), ("work-mac", True), ("server-linux", True), ("cloud-vm", False), ("minimal", False)):
            self.assertEqual(m.resolve_features_non_interactive(self.pf, m.BUNDLES[name], "macos")["installPersonalTools"], expected)
        self.assertFalse(m.DOCKER_ARG_DEFAULTS["installPersonalTools"])

    def test_unrelated_headless_change_cannot_adopt_suite_implicitly(self):
        current = {"profile": "macos", "installExtraRuntimes": False}
        with patch.object(m, "detect", return_value=self.pf), patch.object(m, "print_preflight"), patch.object(m, "read_current_config", return_value=current), patch.object(m, "run_chezmoi") as execute, patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(m.run_reconfigure(m.ReconfigureCmd(set=("installLlmTools=false",), yes=True)), 2)
        execute.assert_not_called()

    def test_explicit_choice_preserves_other_values_and_prompt_override(self):
        current = {"profile": "macos", "name": "Fixture User", "email": "fixture@example.test", "installExtraRuntimes": False, "installLlmTools": False}
        with patch.object(m, "detect", return_value=self.pf), patch.object(m, "print_preflight"), patch.object(m, "print_recap"), patch.object(m, "read_current_config", return_value=current), patch.object(m, "run_chezmoi", return_value=0) as execute:
            self.assertEqual(m.run_reconfigure(m.ReconfigureCmd(set=("installPersonalTools=true",), yes=True, no_apply=True)), 0)
        argv = execute.call_args.args[0]
        self.assertIn("--prompt", argv)
        self.assertNotIn("--apply", argv)
        self.assertIn(m._by_key("installPersonalTools").prompt_text + "=true", argv)
        self.assertIn(m._by_key("installExtraRuntimes").prompt_text + "=false", argv)
        self.assertFalse(current["installLlmTools"])


if __name__ == "__main__":
    unittest.main()
