# `prefix+t` returns the whole pane untranslated (exit 0, no error, LLM billed)

**Symptoms** (grep this section): `prefix+t` / *Translate pane* opens its viewer and shows the pane's content back **verbatim** with no `  ↳ ` translation lines under any paragraph; a handful of top-level lines translate while everything indented does not; `translate -2` "works" from a plain file but not on a pane capture; exit status is 0, stderr is empty, `translate history` shows a normal call, and the provider was billed for it. Also reachable as: `--bilingual` returns only the original; bilingual mode treats prose as code; `translate` skipped my paragraphs.
**First seen**: 2026-08-31, while building `dot_config/herdr/executable_pane-translate.sh`
**Affects**: any pipeline feeding a captured terminal screen into `translate -2` — the herdr pane translator here and its `pane-translate.ps1` port in `dotfiles-windows`. Generic to `translate`'s bilingual mode, not herdr-specific.
**Status**: fixed — dedent by the **modal** indent before piping.

## Symptom

A Claude Code pane translated with `translate -2 --bilingual-mode doc` came back
as an exact copy of the input. No error, no warning, exit 0:

```
     - Edit docs/parity-matrix.md — extend the herdr row with the capability
       exception (popup vs pane for prefix+t).

     Per the cross-cutting rule: one backlog doc, in the repo that holds the code —
     here that is the Windows verification item, since the Unix side ships complete.
```

Every line is present; not one `  ↳ ` line was added.

## Root cause

`translate`'s bilingual splitter (`internal/bitext/bitext.go`) classifies each
blank-line-delimited block as `Prose` or `Code`, and the test is **relative**: a
block is `Code` once its indent is at least `codeIndent = 2` past the document's
base margin. Code blocks are passed through verbatim — by design, so `ls -l` and
stack traces are not mangled.

A coding-agent TUI renders its entire transcript behind a uniform left margin.
Feed the capture in raw and every paragraph sits ≥ 2 past the base, so the whole
page is classified as code and copied through. The call still succeeds, which is
what makes this expensive rather than merely annoying.

The obvious fix — dedent by the minimum indent — **does not work**, and this is
the part worth remembering. An agent transcript is not uniformly indented; it
mixes markers at column 0 with prose further in:

```
indent histogram: [(0, 3), (2, 4), (5, 40), (243, 1)]
'⏺ Now the Unix helper.'          <- indent 0
'  Ran 3 shell commands'          <- indent 2
'     The TUI currently renders…' <- indent 5  (the prose, 40 of 48 lines)
```

`min()` is 0, so a min-based dedent removes nothing and the page is lost exactly
as before.

## Fix

Dedent by the **modal** indent — the pane's dominant text column:

```python
counts = {}
for n in indents:
    counts[n] = counts.get(n, 0) + 1
top = max(counts.values())
base = min(n for n, c in counts.items() if c == top)   # 5, not 0
```

Prose lands at column 0 and is translated; a genuinely nested code block (the
`$ just bats` example at indent 9) keeps a relative indent of 4 and stays
classified as code, which is the behaviour you actually want. Strip
`min(base, actual_indent)` per line so the column-0 markers are not truncated.

## How it is kept fixed

`tests/unit/herdr_pane_translate.bats` asserts prose reaches column 0 *and* that a
deeper block does not, against `tests/fixtures/herdr/pane-capture.txt` — a fixture
built to contain all three indent levels. The Windows port asserts the same
fixture byte-for-byte in `dotfiles-windows/tests/HerdrPaneTranslate.Tests.ps1`.

To see the pre-translation text without spending a call:

```bash
~/.config/herdr/pane-translate.sh visible "$HERDR_PANE_ID" --dry-run
```

If the prose in that output is still indented, this bug is back.

## See also

- [`docs/tools/herdr.md`](../docs/tools/herdr.md) § Translate a pane
- The superproject's `docs/herdr-pane-capture.md` — the shared capture contract.
