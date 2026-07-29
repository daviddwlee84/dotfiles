# View Office Documents in the Terminal

Open and preview Microsoft Office (`.docx` / `.xlsx` / `.pptx`), legacy binary (`.doc` / `.xls` / `.ppt`), and OpenDocument (`.odt` / `.ods` / `.odp`) files without leaving the terminal — no Microsoft Office, no GUI.

There is no single tool that views everything well, so this repo wires a small **per-format + two-mode** stack behind one dispatcher, [`view-office`](#the-view-office-dispatcher), and hooks it into the [yazi](tmux/README.md) file manager for inline previews.

## TL;DR

| Format | Interactive (TUI / pager) | Quick preview (stdout) |
|---|---|---|
| Word `.docx` | [`doxx`](https://github.com/bgreenwell/doxx) | `doxx --export ansi` |
| Excel `.xlsx` | [`visidata`](https://www.visidata.org/) (`vd`) | `markitdown \| glow` |
| PowerPoint `.pptx` | `markitdown \| glow` (pager) | `markitdown \| glow`; image-only decks → slide-1 thumbnail (chafa) |
| Legacy `.doc/.xls/.ppt`, OpenDocument `.odt/.ods/.odp`, `.rtf` | LibreOffice → OOXML twin → above | same, converted first |

```console
$ view-office report.docx                 # interactive: rich TUI (doxx)
$ view-office --preview budget.xlsx        # markdown/ANSI to stdout
$ view-office legacy-memo.doc              # LibreOffice converts, then doxx
```

## The `view-office` dispatcher

`view-office` (source: `dot_dotfiles/bin/executable_view-office`, deployed to `~/.dotfiles/bin/`, on `PATH`) is a small bash script that dispatches by file extension:

```text
view-office [--preview] [--width N] FILE
  -p, --preview    render to stdout (ANSI/markdown) instead of launching a TUI
  -w, --width N    wrap width for --preview (default: $COLUMNS or 100)
  -h, --help       show help
```

Two modes:

- **Interactive** (default) — launches the best full-screen viewer for the type: `doxx` for Word, `visidata` for Excel, a `glow` pager for PowerPoint.
- **Preview** (`--preview`) — emits ANSI/markdown to stdout. This is the single source of truth that the [yazi previewer](#yazi-inline-previews) (and any future `tv` / `fzf` integration) calls, so preview logic lives in exactly one place.

Legacy binary and OpenDocument formats are converted to their modern OOXML twin with **LibreOffice headless** into a temp dir, then re-dispatched to the handler above (e.g. `.doc → .docx → doxx`). Missing tools produce an actionable install hint and exit 2 — nothing fails silently.

> **Why bash, not the `uv run --script` pattern** used by `pqsum`/`yth`/`mlf`? `view-office` sits on yazi's preview hot-path (invoked on every file hover). uv/Python startup (~100–200 ms) would make previews feel laggy; bash dispatch is ~5 ms.

## The tools

### doxx — terminal-native Word viewer

[doxx](https://github.com/bgreenwell/doxx) renders `.docx` directly in the terminal: bold/italic/headings, smart tables, LaTeX equations, and inline images (Kitty/iTerm2/Sixel). It also exports non-interactively — `doxx FILE --export ansi|markdown|text|csv|json` — which is what `view-office --preview` uses for Word.

- **macOS:** `brew install doxx` (it's in **homebrew-core** — the README's `bgreenwell/tap/doxx` is stale; that tap ships `xleak`/`lstr`, not doxx).
- **Linux:** GitHub release `.tar.xz` (cargo-dist, static musl on x86_64) → `~/.local/bin/doxx`, installed by the `devtools` ansible role.

### visidata — spreadsheet multitool

Already in the repo (see [Data Viewers](../shells/aliases.md)). `vd file.xlsx` opens a fast, vim-keyed TUI over the sheet. Used for **interactive** Excel; for previews, `markitdown` renders the sheet to a markdown table instead (visidata is TUI-only).

### markitdown — Office → Markdown

[Microsoft MarkItDown](https://github.com/microsoft/markitdown) converts `.docx/.xlsx/.pptx` (and more) to Markdown, optimized for LLM/RAG pipelines. It is the universal preview engine for Excel and PowerPoint here, because **pandoc cannot read `.pptx` or `.xlsx`** (pandoc only *writes* pptx; it reads docx/odt/epub but not the spreadsheet/presentation formats). Installed as a uv tool (`python_uv_tools`).

> **Gotcha:** the bare `markitdown` package ships **no format converters** — they live in optional extras. This repo installs `markitdown[docx,xlsx,pptx]`; without the extras every Office file raises `MissingDependencyException`. (Not `[all]` — that adds pdf/audio/youtube/azure bloat.)

> **Image-only `.pptx`:** markitdown extracts *text*, so a deck whose slides are full-page images yields nothing but `![](imageN)` refs. For `--preview`, `view-office`'s `render_pptx` detects this by peeking at the slide XML with 7-Zip; if there's no text it extracts the first embedded slide image (`ppt/media/image1.*`) and renders it with [`chafa`](yazi-previews.md) — ~0.5 s, versus tens of seconds for a full LibreOffice slide render on image-heavy decks. Text decks still get the markitdown path.

### LibreOffice — legacy-format fallback

Only `soffice --headless --convert-to` can read the old binary formats (`.doc/.xls/.ppt`) and OpenDocument. Heavy (~hundreds of MB), so it's a **fallback**, installed by `devtools` (macOS cask / `libreoffice-writer,calc,impress` on Debian with recommends off). On macOS `soffice` is not on `PATH`; `view-office` resolves the `.app` bundle path itself. No-root Linux installs skip it and `view-office` prints an install hint for legacy files.

## Yazi inline previews

Hovering an Office file in [yazi](tmux/README.md) renders a preview in the right pane. This is the repo's first yazi **plugin** integration, via the [`ya pkg`](#the-ya-pkg-plugin-mechanism) manager and the [`piper.yazi`](https://github.com/yazi-rs/plugins/tree/main/piper.yazi) plugin ("pipe any shell command as a previewer"):

```toml
# dot_config/yazi/yazi.toml
[plugin]
prepend_previewers = [
  { url = "*.docx", run = 'piper -- view-office --preview --width "$w" "$1"' },
  # … .pptx .doc .xls .ppt .odt .ods .odp .rtf
]
```

> **`.xlsx` preview is handled by [duckdb.yazi](data-viewers.md), not `view-office`.** Yazi routes
> spreadsheet hovers to the DuckDB table previewer (a nicer aligned grid). The
> `view-office --preview budget.xlsx` **CLI** path (markitdown → glow) is unchanged — only Yazi's
> previewer wiring moved. Legacy `.xls` / OpenDocument `.ods` stay on the view-office (LibreOffice)
> path here, since DuckDB can't read those.

`piper.yazi` passes `$w` (preview width) and `$1` (file path); the command's stdout becomes the preview. The `run` string and `view-office`'s `--preview`/`--width` interface are a **contract** — change one, change the other.

### The `ya pkg` plugin mechanism

`ya pkg` is Yazi's plugin manager (`ya` is the CLI companion shipped with yazi). It clones a plugin, copies it into `~/.config/yazi/plugins/`, and locks its version in `~/.config/yazi/package.toml`.

> **`ya` must actually be installed.** It ships in the same release archive as the `yazi` binary, but an install that copies out only `yazi` leaves you with no `ya`, no `~/.config/yazi/plugins/`, and therefore no Office previews at all — surfacing much later as a startup crash blaming whichever plugin `init.lua` requires first. Diagnose with `ya --version`. See [pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md).

In this repo the lockfile is **chezmoi-managed** (`dot_config/yazi/package.toml`) and the plugins are materialized by a self-healing run-script:

| Piece | Path | Role |
|---|---|---|
| Lockfile (SSOT) | `dot_config/yazi/package.toml` | pins `yazi-rs/plugins:piper` (rev + hash) |
| Installer | `.chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl` | runs `ya pkg install` when a plugin is missing or the lockfile changed |
| Previewer wiring | `dot_config/yazi/yazi.toml` `[plugin]` | maps Office extensions → `piper -- view-office …` |

`ya pkg install` **rewrites** `package.toml` (normalizes it and drops comments), so the managed source lockfile is kept **comment-free** to match its canonical output — that's what avoids chezmoi drift. It is install-only by design (like the rest of the repo) — bump plugin versions with `ya pkg upgrade` (`just upgrade-yazi-plugins`), then copy the regenerated `~/.config/yazi/package.toml` back into the source.

Add another yazi plugin:

```bash
ya pkg add <owner>/<repo>:<plugin>       # installs + updates ~/.config/yazi/package.toml
cp ~/.config/yazi/package.toml "$(chezmoi source-path ~/.config/yazi/package.toml)"
```

## Where things live

| Surface | Path |
|---|---|
| Dispatcher CLI | `dot_dotfiles/bin/executable_view-office` |
| Completions (zsh/bash) | `dot_config/{zsh/tools,bash}/55_view_office_completion.*` |
| doxx / LibreOffice install | `dot_ansible/roles/devtools/tasks/main.yml` |
| markitdown install | `dot_ansible/roles/python_uv_tools/defaults/main.yml` |
| yazi previewers | `dot_config/yazi/yazi.toml` |
| yazi plugin lockfile + installer | `dot_config/yazi/package.toml`, `.chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl` |
| Upgrades | `scripts/upgrade_tools.sh` (`just upgrade-yazi-plugins`) |

## Gotchas

- **`markitdown` needs extras** — see the box above. `markitdown[docx,xlsx,pptx]`, not bare `markitdown`.
- **pandoc ≠ Office reader** — it cannot read `.pptx`/`.xlsx`. Use `markitdown` for those. (pandoc still powers the [web reader](web-reader.md) for HTML.)
- **Uppercase extensions** — the yazi `url` globs are lowercase (`*.docx`); a file named `Report.DOCX` won't trigger the previewer (running `view-office` directly still works — it lowercases internally).
- **LibreOffice cold start** — legacy-format previews spin up a fresh isolated headless soffice profile **on every hover** (no caching — each invocation `mktemp`s its own profile), so `.doc/.xls/.ppt/ODF` previews take **~7 s each** (measured; more on large files). yazi runs previewers asynchronously so the UI stays responsive, but the pane is blank until it lands. Modern OOXML formats don't touch LibreOffice and are instant.
- **PATH in yazi previews** — `piper` runs the command via `sh`; `view-office` must be on the `PATH` yazi inherited. Launch yazi from a configured shell so `~/.dotfiles/bin` is present.

## See also

- [Data Viewers](../shells/aliases.md) — VisiData wrappers.
- [Web reader](web-reader.md) — read HTML pages as markdown (the pandoc/`glow` sibling).
- [tool-managers.md](../this_repo/tool-managers.md) — install-side index (doxx, markitdown, libreoffice, `ya pkg`).
