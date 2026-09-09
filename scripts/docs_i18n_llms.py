"""Keep llmstxt section aliases aligned with pages rendered by suffix i18n.

The pinned plugins may retain both base and localized source URIs in a section,
while only one counterpart is rendered in a language build. Remap only aliases
with a rendered counterpart; genuine missing selections still produce warnings.
"""
from pathlib import Path, PurePosixPath

from mkdocs.plugins import CombinedEvent, event_priority


def _base(uri, locales):
    path = PurePosixPath(uri)
    for locale in locales:
        suffix = f".{locale}.md"
        if path.name.endswith(suffix):
            return str(path.with_name(path.name[: -len(suffix)] + ".md"))
    return uri


@event_priority(100)
def _remap_sections(config):
    llms = config.plugins.get("llmstxt")
    i18n = config.plugins.get("i18n")
    if llms is None or i18n is None:
        return
    # This adapter is version-bound by uv.lock. Fail visibly if an upgrade
    # changes the plugin contract rather than silently dropping source links.
    rendered = llms._md_pages
    locales = tuple(i18n.all_languages)
    counterparts = {_base(uri, locales): uri for uri in rendered}
    llms._sections = {
        title: {
            uri if uri in rendered else counterparts.get(_base(uri, locales), uri): description
            for uri, description in selections.items()
        }
        for title, selections in llms._sections.items()
    }



@event_priority(-50)
def _publish_locale_exports(config):
    # Run after llmstxt (0), before i18n starts its next build (-100).
    llms = config.plugins.get("llmstxt")
    i18n = config.plugins.get("i18n")
    if llms is None or i18n is None:
        return
    names = ["llms.txt"]
    if llms.config.full_output is not None:
        names.append(llms.config.full_output)
    root = Path(config.site_dir)
    if i18n.current_language == i18n.default_language:
        llms._i18n_default_exports = {name: (root / name).read_bytes() for name in names}
        return
    for name in names:
        source = root / name
        destination = root / i18n.current_language / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
        source.write_bytes(llms._i18n_default_exports[name])


on_post_build = CombinedEvent(_remap_sections, _publish_locale_exports)
