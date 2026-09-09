import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
import tempfile

try:
    import mkdocs  # Optional docs extra; generic unit discovery need not install it.
except ModuleNotFoundError:
    raise unittest.SkipTest("docs extra is required")

_spec = importlib.util.spec_from_file_location(
    "docs_i18n_llms", Path(__file__).parents[2] / "scripts/docs_i18n_llms.py"
)
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)


class LocaleExportTests(unittest.TestCase):
    def test_maps_localized_counterparts_without_hiding_missing_pages(self):
        llms = SimpleNamespace(
            config=SimpleNamespace(full_output="llms-full.txt"),
            _md_pages={"index.zh-TW.md": object(), "fallback.md": object()},
            _sections={"Pages": {"index.md": "", "index.zh-TW.md": "", "fallback.md": "", "missing.md": ""}},
        )
        config = SimpleNamespace(plugins={"llmstxt": llms, "i18n": SimpleNamespace(all_languages=["en", "zh-TW"], current_language="zh-TW",default_language="en")})
        _module._remap_sections(config)
        self.assertEqual(list(llms._sections["Pages"]), ["index.zh-TW.md", "fallback.md", "missing.md"])

    def test_locale_exports_do_not_overwrite_the_default_language(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            llms = SimpleNamespace(config=SimpleNamespace(full_output="llms-full.txt"))
            i18n = SimpleNamespace(current_language="en", default_language="en")
            config = SimpleNamespace(site_dir=directory, plugins={"llmstxt": llms, "i18n": i18n})
            for name in ["llms.txt", "llms-full.txt"]:
                (root / name).write_text("English")
            _module._publish_locale_exports(config)
            i18n.current_language = "zh-TW"
            for name in ["llms.txt", "llms-full.txt"]:
                (root / name).write_text("繁體中文")
            _module._publish_locale_exports(config)
            for name in ["llms.txt", "llms-full.txt"]:
                self.assertEqual((root / name).read_text(), "English")
                self.assertEqual((root / "zh-TW" / name).read_text(), "繁體中文")



if __name__ == "__main__":
    unittest.main()
