import os
from pathlib import Path
import subprocess
import tempfile
import unittest

try:
    import tomllib
except ModuleNotFoundError:
    raise unittest.SkipTest("Python 3.11+ is required to inspect the channel")


class SSHChannelSourceTests(unittest.TestCase):
    def test_capability_gate_and_grouped_fallback(self):
        channel = Path(__file__).parents[2] / "dot_config/television/cable/ssh-config.toml"
        source = tomllib.loads(channel.read_text())["source"]["command"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".ssh/config.d/work").mkdir(parents=True)
            (root / ".ssh/config").write_text("Host root-alias\n")
            (root / ".ssh/config.d/work/box.conf").write_text("Host grouped-alias\n")
            binaries = root / "bin"
            binaries.mkdir()
            dev = binaries / "dev"
            # Older Cobra groups can return success for unknown-command --help.
            dev.write_text("#!/bin/sh\nif [ \"$2\" = manage ]; then echo 'Usage: dev ssh'; else echo OLD_PARSER_MUST_NOT_RUN; fi\n")
            dev.chmod(0o700)
            environment = dict(os.environ, HOME=str(root), PATH=f"{binaries}:/usr/bin:/bin")
            old = subprocess.check_output(["bash", "-c", source], env=environment, text=True)
            self.assertIn("root-alias", old)
            self.assertIn("grouped-alias", old)
            self.assertNotIn("OLD_PARSER", old)
            dev.write_text("#!/bin/sh\nif [ \"$2\" = manage ]; then echo '  --herdr-profile stringArray'; else printf 'active-alias\\tactive\\tforeign\\t/source\\t1\\t\\ninactive-alias\\tinactive\\tforeign\\t/source\\t2\\t\\n'; fi\n")
            current = subprocess.check_output(["bash", "-c", source], env=environment, text=True)
            self.assertEqual(current.strip(), "/source\tactive-alias")


if __name__ == "__main__":
    unittest.main()
