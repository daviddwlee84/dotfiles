"""Render the uv template with optional cache data and validate it with uv."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "dot_config/uv/uv.toml.tmpl"
MIRRORS = [
    "https://mirrors.aliyun.com/pypi/simple/",
    "https://pypi.tuna.tsinghua.edu.cn/simple/",
    "https://pypi.mirrors.ustc.edu.cn/simple/",
]


@unittest.skipUnless(shutil.which("chezmoi"), "chezmoi unavailable")
class UvConfigTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.config = self.tmp / "chezmoi.toml"
        self.config.write_text("")
        self.template = TEMPLATE.read_text()

    def cases(self):
        overrides = (
            ("missing", {}),
            ("empty", {"uvCacheDir": ""}),
            ("custom", {"uvCacheDir": str(self.tmp / "uv-cache")}),
            ("escaped", {"uvCacheDir": str(self.tmp / 'cache dir "quoted" \\ path')}),
        )
        for mirror in (False, True):
            for label, override in overrides:
                yield label, {"useChineseMirror": mirror, **override}

    def render(self, data):
        result = subprocess.run(
            ["chezmoi", "--config", str(self.config), "--source", str(ROOT),
             "execute-template", "--override-data", json.dumps(data)],
            input=self.template, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_optional_cache_and_mirror_tables(self):
        for label, data in self.cases():
            with self.subTest(override=label, mirror=data["useChineseMirror"]):
                expected = {}
                if data["useChineseMirror"]:
                    expected = {
                        "index-strategy": "unsafe-first-match",
                        "index": [{"url": url} for url in MIRRORS],
                        "pip": {"index-url": MIRRORS[0], "extra-index-url": MIRRORS[1:]},
                    }
                if data.get("uvCacheDir"):
                    expected["cache-dir"] = data["uvCacheDir"]
                self.assertEqual(tomllib.loads(self.render(data)), expected)

    @unittest.skipUnless(shutil.which("uv"), "uv unavailable")
    def test_uv_accepts_rendered_config_and_resolves_cache(self):
        # Ignore inherited uv overrides and keep discovery/cache paths isolated.
        env = {key: value for key, value in os.environ.items() if not key.startswith("UV_")}
        env.update({
            "HOME": str(self.tmp),
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
            "XDG_CACHE_HOME": str(self.tmp / "default-cache"),
        })

        def cache_dir(*options):
            result = subprocess.run(
                ["uv", "--offline", *options, "cache", "dir"],
                cwd=self.tmp, env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

        default_cache = cache_dir("--no-config")
        config = self.tmp / "uv.toml"
        for label, data in self.cases():
            with self.subTest(override=label, mirror=data["useChineseMirror"]):
                config.write_text(self.render(data))
                self.assertEqual(
                    cache_dir("--config-file", str(config)),
                    data.get("uvCacheDir") or default_cache,
                )


if __name__ == "__main__":
    unittest.main()
