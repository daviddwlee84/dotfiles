# MkDocs cannot find an existing script document in nav

Symptom:

```text
A reference to 'this_repo/scripts/import_ssh_to_bw.sh.md' is included in the 'nav' configuration, which is not found in the documentation files.
```

The suffix i18n plugin interprets `.sh` as a locale, so the existing English
Markdown file is filtered out. Name the English source
`import_ssh_to_bw.sh.en.md`; keep the canonical nav/link target `.sh.md` and the
existing `.sh.zh-TW.md` translation. The plugin resolves default/current locale
sources while retaining the intended public `.sh/` route.

The same strict build also exposed llmstxt/i18n source alias drift: a section can
retain `index.md` while the rendered source is `index.zh-TW.md`. Keep localized
section glob selectors and `scripts/docs_i18n_llms.py` together. The hook maps only
to an actually rendered counterpart; genuinely missing pages still warn. The
pinned plugin API is covered by a focused test and the full bilingual strict build.
