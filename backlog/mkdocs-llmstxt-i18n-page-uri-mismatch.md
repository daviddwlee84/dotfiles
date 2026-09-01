# `llms.txt` silently drops every page that has a zh-TW translation

**Status**: P2 ready (root cause identified, fix not chosen)
**Effort**: M
**Related**: [`mkdocs.yml`](../mkdocs.yml) `plugins.llmstxt.sections` + `plugins.i18n` · [`.github/workflows/docs.yml`](../.github/workflows/docs.yml)

## Context

**2026-09**: found while fixing the `social` plugin (see
[`pitfalls/mkdocs-social-plugin-cairosvg-not-found-macos.md`](../pitfalls/mkdocs-social-plugin-cairosvg-not-found-macos.md)).
The social plugin was emitting **347** warnings on every local build, which
drowned out everything else and made `mkdocs build --strict` unrunnable — so
nobody ever saw these 11.

With social fixed, `--strict` drops to 12 warnings, and 11 of them are:

```
WARNING -  mkdocs_llmstxt: Page URI 'index.md' not found in the generated pages. Skipping.
WARNING -  mkdocs_llmstxt: Page URI 'tools/aicapture.md' not found in the generated pages. Skipping.
WARNING -  mkdocs_llmstxt: Page URI 'tools/tmux/README.md' not found in the generated pages. Skipping.
…
```

## Root cause

The correlation is exact. Of the 12 pages listed under `plugins.llmstxt.sections`
in `mkdocs.yml`, the **11 that have a `.zh-TW.md` twin all fail**, and the one
that does not (`tools/ai-agents-benchmark.md`) is the only one that works:

```sh
$ for f in <the 11 failing>; do test -f "docs/${f%.md}.zh-TW.md" && echo YES; done
YES × 11
$ test -f docs/tools/ai-agents-benchmark.zh-TW.md   # -> no
```

`mkdocs-static-i18n` runs with `docs_structure: suffix` and, for any page with a
translated twin, **replaces the default-locale `File` object** with one it builds
itself. `mkdocs-llmstxt` resolves its configured `sections:` URIs against the
file set afterwards and no longer finds them, so it skips the page.

**Impact**: `llms.txt` / `llms-full.txt` currently contain **1 of the 12
curated pages** — everything that actually matters for agent consumption
(`index`, `aicapture`, `tmux`, `sesh`, `fleet-apply`, `architecture`,
`agent-overlays`, `clipboard`, `workflow`, `zsh-inline-ai`,
`instant-llm-fix-prior-art`) is missing. This has presumably been true since
i18n was introduced; the output is generated and published without anyone
reading it.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| Point `sections:` at the i18n-rewritten URIs | Possibly a pure `mkdocs.yml` edit | Need to discover the real URIs first; likely locale-prefixed and would break the zh-TW build or CI if the scheme changes |
| Reorder `plugins:` so `llmstxt` runs before `i18n` | No URI churn | MkDocs plugin ordering is load order; llmstxt hooks `on_files`/`on_page_content` and may simply not see final content |
| Drop the pages' zh-TW twins from i18n's view (`exclude`) | Restores llmstxt | Loses the translations from the site — non-starter |
| Upstream fix / issue in `mkdocs-llmstxt` | Correct long-term | No ETA; needs a minimal repro |

## Next step

Reproduce with a 3-file scratch site (one page with a `.zh-TW.md` twin, one
without) to confirm the mechanism, then decide between re-pointing `sections:`
and filing upstream. Verify with `just docs-build` — after the fix the strict
build should be down to the single remaining `nav` warning for
`this_repo/scripts/import_ssh_to_bw.sh.md` (also unexplained; likely the same
i18n suffix parser choking on the `.sh.md` double extension, worth checking in
the same session).
