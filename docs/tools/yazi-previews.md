# Yazi Preview Coverage

Maximize what the [yazi](tmux/README.md) file manager can preview on hover — **images, PDF, video,
SVG, archives, ebooks, dmg**, on top of the tabular/office stacks documented in
[data-viewers.md](data-viewers.md) and [office-viewers.md](office-viewers.md).

The catch: yazi's **built-in** previewers (images / PDF / video / SVG / standard archives) are *not*
wired in `dot_config/yazi/yazi.toml` — yazi ships them internally and **shells out to external
binaries at runtime**. If those binaries aren't installed, the hover pane shows an error
(`failed to spawn chafa`) or bare file-type classification. So "expanding coverage" is mostly a
**tool-install** job (a few ansible-managed binaries), plus a handful of small config rules for the
container / e-book formats yazi ignores by default.

## TL;DR — coverage matrix

| File type | Preview | Powered by | Tier |
|---|---|---|---|
| png / jpg / webp / gif / bmp | image (or unicode-art) | yazi built-in → **chafa** to display | baseline |
| **PDF** | first page as image | yazi built-in → **poppler** (`pdftoppm`) + chafa | baseline |
| **SVG** | rendered image | yazi built-in → **resvg** + chafa | baseline |
| archives: zip / tar / gz / 7z / rar (+ zip-based apk / jar / whl / xpi) | file listing | yazi built-in → **7-Zip** | baseline |
| **dmg** | file listing | piper → **7-Zip** (`*.dmg` rule) | baseline |
| **EPUB** | text | piper → **pandoc** (`*.epub` rule) | baseline |
| **Kindle** .mobi / .azw / .azw3 / .fb2 | metadata (title/author/description) | piper → **view-ebook** → calibre `ebook-meta` | opt-in (installCalibre) |
| video: mp4 / mkv / mov … | thumbnail | yazi built-in → **ffmpeg** + chafa | media (gated) |
| HEIC / JPEG-XL / fonts | image / sample | yazi built-in → **ImageMagick ≥7.1.1** + chafa | media (gated) |
| csv / tsv / parquet / xlsx / db / sqlite / feather | table | duckdb.yazi + fallbacks | plugin — see [data-viewers.md](data-viewers.md) |
| docx / **pptx** / legacy / ODF | text (image-only pptx → slide-1 thumbnail) | view-office (doxx / markitdown / chafa / LibreOffice) | plugin — see [office-viewers.md](office-viewers.md) |
| **Markdown** .md / .markdown | rendered (headings, tables, code blocks) | piper → **glow** (`*.md` rule) | baseline |
| txt / json / source | text (+ syntax) | yazi built-in / `bat` | always |

- **Baseline** tools are installed unconditionally by the `devtools` role (next to yazi).
- **Media (gated)** tools live in the `media_tools` role behind the `installMediaTools` prompt
  (default **off**; forced off on server/minimal). Video + HEIC previews work only where you opted in.

## Why images showed `failed to spawn chafa`

Every image-derived preview funnels through the same final **display** step. yazi renders png (direct),
PDF (via poppler), video (via ffmpeg), HEIC (via ImageMagick), SVG (via resvg) all *to an image*, then
hands that image to the display adapter it auto-selected. yazi picks the adapter from your terminal:
Kitty graphics protocol, iTerm2 inline, Sixel, Überzug++ (X11/Wayland), and — when none of those is
available (a non-graphics terminal, or inside tmux without passthrough) — **chafa**, its documented
*"last fallback resort"* that draws the image as Unicode/ANSI art.

So a missing `chafa` breaks **all** of png/pdf/mp4/HEIC at once, even though poppler/ffmpeg/magick are
present — they produce the image fine; nothing can display it. Installing `chafa` fixes the whole set.

### Which terminal gets crisp images vs ascii-art

chafa gives **universal ASCII/ANSI-art** previews that work everywhere — over tmux, SSH, any terminal.
For **crisp inline images**, run yazi in a terminal that speaks an image graphics protocol; yazi
auto-detects it (from `$TERM` / `$TERM_PROGRAM` / `$XDG_SESSION_TYPE`) and upgrades the adapter, no
config change. yazi's adapters, in priority order:

| Adapter | Protocol | Terminals (non-exhaustive) |
|---|---|---|
| **Kgp** | Kitty graphics protocol | **kitty**, **Ghostty** / **cmux**, WezTerm, Konsole, wayst |
| **Iip** | iTerm2 inline images | **iTerm2**, WezTerm, Warp, Rio, Tabby, VSCode (partial) |
| **Sixel** | Sixel | foot, Contour, mlterm, WezTerm, Windows Terminal, Rio, xterm (`+sixel`) |
| **X11 / Wayland** | Überzug++ overlay | any terminal on Linux X11/Wayland (needs Überzug++ installed) |
| **Chafa** | Unicode / ANSI art | **everything else** — Alacritty, macOS Terminal.app, tmux-without-passthrough, plain SSH |

- **No native protocol → chafa.** Notably **Alacritty** and **macOS Terminal.app** have *no* image
  protocol, so yazi always falls back to chafa there (this repo's [`--probe off` shim](#chafa-probe-leak)
  keeps that path clean). Ghostty / cmux / kitty / iTerm2 / WezTerm give real inline images.
- **Inside a multiplexer** the *terminal* still has to support the protocol AND the mux has to pass it
  through: tmux needs `allow-passthrough on` (set here in `dot_config/tmux/common.conf.tmpl`) — but the
  legacy `KgpOld` variant doesn't work under tmux, and Sixel needs a `--enable-sixel` tmux build. zellij's
  image support is limited and shares the same [OSC-query leak](#chafa-probe-leak) class as the chafa bug.
- **See which adapter yazi picked**: `yazi --debug` → the `Adapter.matches` line.

If you only ever get ascii-art, that's the terminal/tmux graphics story, **not** a missing tool — chafa
is doing its job. See yazi's [image-preview docs](https://yazi-rs.github.io/docs/image-preview/).

### Large images: "Image size exceeds limit" {#image-size-limit}

A big screenshot or a wide time-series / plot PNG can show **`Image size exceeds limit`** instead of a
preview. That's yazi's **decode** guard, not the terminal: yazi decodes the image with the `image`
crate bounded by `[tasks] image_bound` (default **`[10000, 10000]`** px) *before* downscaling to the
small `[preview] max_width`/`max_height` (600×900), so anything over 10000 px on a side is rejected up
front (confirmed in `yazi-adapter`: `limits.max_image_width = Some(YAZI.tasks.image_bound[0])`). This
repo raises the bound in `dot_config/yazi/yazi.toml`:

```toml
[tasks]
image_bound = [ 30000, 30000 ]   # image_alloc (512 MB, kept from the preset) stays the memory guard
```

Then run **`yazi --clear-cache`** (a cached failed preview persists) and restart yazi (config is read at
launch). cmux / Ghostty then display the downscaled image fine over Kitty graphics.

### The `chafa` probe leak — spurious rename / shell popup {#chafa-probe-leak}

**Symptom:** hovering an image / PDF / video pops up a `Shell:` or rename prompt containing
`rgb:d8d8/d8d8/d8d8…11;rgb:1818/1818/1818` — junk you never typed.

**Cause:** that string is the terminal's reply to chafa's **OSC 10 / 11** foreground/background color
queries (chafa ≥1.16 probes on every render), with the escape framing stripped. Inside a multiplexer
(tmux / zellij) chafa often exits before the mux delivers the reply, so the mux hands the `rgb:…` bytes
to whatever now owns the tty — yazi — which reads them as keystrokes and opens a prompt. Upstream calls
this a multiplexer bug: [yazi #3680](https://github.com/sxyazi/yazi/issues/3680) (closed *not planned*),
[zellij #5138](https://github.com/zellij-org/zellij/issues/5138) (same class). It bites hardest in
terminals with **no native graphics protocol** (e.g. Alacritty), where yazi must use chafa.

**Fix (in this repo):** a `chafa` wrapper at `dot_dotfiles/bin/executable_chafa` (→ `~/.dotfiles/bin/chafa`,
which precedes brew on `PATH`) forces **`--probe off`** — chafa never sends the query, so nothing leaks.
yazi hardcodes the bare `chafa` call with no way to pass flags, so shadowing the binary is the only
lever. `--probe off` merely disables color auto-detection (chafa falls back to `$TERM`/`$COLORTERM`
defaults; previews look the same), and the shim is **inert on graphics terminals** (yazi never calls
chafa there). Caveat: launch yazi from a configured shell so `~/.dotfiles/bin` is on `PATH`.

## Config-wired previewers (Markdown · EPUB · Kindle · dmg)

Everything above except Markdown, EPUB, Kindle e-books, and dmg is pure tool-install — yazi's built-ins
handle the routing. Those four are wired explicitly in `dot_config/yazi/yazi.toml` via
[`piper.yazi`](office-viewers.md#the-ya-pkg-plugin-mechanism) — the last three because their mimes
aren't in yazi's built-in sets at all, Markdown because we deliberately **override** a built-in that
works:

```toml
{ url = "*.md",   run = 'piper -- glow -w "$w" -s "$t" "$1" 2>/dev/null || cat "$1"' },  # + *.markdown
{ url = "*.epub", run = 'piper -- pandoc -f epub -t plain "$1" 2>/dev/null | head -n 500' },
{ url = "*.mobi", run = 'piper -- view-ebook --preview --width "$w" "$1"' },  # + *.azw *.azw3 *.fb2
{ url = "*.dmg",  run = 'piper -- ( 7zz l "$1" 2>/dev/null || 7z l "$1" 2>/dev/null ) | head -n 200' },
```

- **Markdown → rendered** via [`glow`](#markdown-glow) — see below.
- **EPUB → full text** via pandoc (pandoc reads EPUB but not the Kindle formats).
- **Kindle `.mobi`/`.azw`/`.azw3`/`.fb2` → metadata** via [`view-ebook`](#kindle-e-books-calibre)
  (calibre `ebook-meta`). There's no fast headless way to render mobi/azw *text*, so the preview is a
  "book back-cover" (title / author / tags / description). Best-effort — nothing shows if calibre is absent.
- **dmg → file listing** via 7-Zip (`7zz`/`7z`).
- `2>/dev/null` is **load-bearing** — piper renders any stderr as an error preview.
- **No rule needed** for `.zip` / `.tar.*` / `.7z` / `.rar` or zip-based `.apk` / `.jar` / `.whl` /
  `.xpi` — yazi's built-in archive previewer lists them for free once 7-Zip is installed.

### Markdown: rendered, not raw {#markdown-glow}

Out of the box yazi previews `.md` with its built-in **`code`** previewer: syntect syntax
highlighting over the *raw source*, so you read `## Heading`, `**bold**`, `| a | b |` and un-fenced
code as literal markup. Useful when you're about to edit the file, much less useful when you're
skimming a README to find out what a repo does.

`glow` renders it instead — headings, emphasis, lists, blockquotes, tables and fenced code blocks
come out as styled text:

```toml
{ url = "*.md", run = 'piper -- CLICOLOR_FORCE=1 glow -w "$w" -s "$t" "$1" 2>/dev/null || cat "$1"' },
```

- **`$w`** is the preview pane width, from piper. glow hard-wraps to exactly that, so nothing
  overflows or gets truncated mid-table when you resize.
- **`$t`** is `dark` or `light`, also from piper — yazi's own terminal background detection, so the
  rendered colors follow the terminal instead of being pinned to a dark palette.
- **`CLICOLOR_FORCE=1` is load-bearing** — see [below](#glow-colorless).
- **`|| cat "$1"`** keeps a plain-text preview (rather than an empty pane) on the rare host where the
  `devtools` role skipped glow because there's no release for the architecture.
- **Scrolling works.** piper re-runs glow and skips `job.skip` lines per scroll step; worst measured
  case is ~160 ms on a 2.8 MB markdown file, so it stays responsive on realistic files.
- **Want the raw source?** `Enter` / `o` opens the file in `$EDITOR` (nvim), which is the natural place
  to read markup anyway. There's no in-yazi toggle back to the built-in previewer.
- **Known cosmetic quirk**: glow prints link *destinations* inline, resolved to absolute paths — a
  relative `[yazi](tmux/README.md)` renders as **yazi** followed by the full
  `/Users/…/docs/tools/tmux/README.md`. That's glow's link style, not a config error; it makes
  link-dense docs (like this repo's) noisier than prose files.

#### Formatted but colorless → `CLICOLOR_FORCE=1` {#glow-colorless}

Without that variable the preview comes out *shaped* correctly — wrapped, indented, bulleted — but
entirely monochrome. It looks like a theme problem; it isn't.

glow renders through glamour → lipgloss → **termenv**, and termenv picks its color profile by probing
stdout. piper hands the child a **pipe**, not a pty, so the probe returns the `Ascii` profile and
glow emits attribute-only escapes — `ESC[;;1m` instead of `ESC[38;5;252;1m`. The bold/reverse bits
survive (hence visible structure), every color component is dropped.

`CLICOLOR_FORCE=1` is the documented termenv override, and it's what the upstream
[`glow.yazi`](https://github.com/Reledia/glow.yazi) plugin sets for the same reason.

One caveat worth knowing: when termenv is *forced* out of an `Ascii` detection it falls back to plain
**ANSI-16**, not 256-color — no combination of `TERM` / `COLORTERM` / `FORCE_COLOR` changes that
(verified). Colors therefore come from your terminal's 16-color palette, so they follow your theme.
Getting glow's native 256-color output would require running it under a real pty; the trade-offs are
recorded in [`backlog/yazi-markdown-preview-truecolor.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/yazi-markdown-preview-truecolor.md).



### Kindle e-books (calibre) {#kindle-e-books-calibre}

`view-ebook` (`dot_dotfiles/bin/executable_view-ebook`) resolves calibre's `ebook-meta` — on PATH,
else the macOS `/Applications/calibre.app` bundle, else the Linux prefix — and prints the book's
metadata (HTML-stripped, wrapped to the pane width). calibre isn't repo-managed by default; enable the
**`installCalibre`** init prompt to have the `devtools` role install it (brew cask on macOS, apt on
Linux). Already have calibre installed by hand? The preview just works, and the macOS cask install is
**skipped** when `/Applications/calibre.app` already exists (Homebrew won't install over an existing app,
and `--adopt` refuses on a version mismatch) — so the prompt only installs calibre where it's absent,
never touching a version you manage yourself. (EPUB stays on pandoc's full-text path, not view-ebook.)

## Per-OS install

| Tool | macOS (brew, `devtools`) | Linux (Debian/Ubuntu) | Enables |
|---|---|---|---|
| **chafa** | `chafa` | apt `chafa` | image display fallback (all image-derived previews) |
| **poppler** | `poppler` | apt `poppler-utils` | PDF |
| **7-Zip** | `sevenzip` (`7zz`) | apt `p7zip-full` (`7z`) | archives + dmg |
| **resvg** | `resvg` | Linuxbrew → `cargo install resvg` (no apt pkg; non-fatal if absent) | SVG |
| ffmpeg | `ffmpeg` (`media_tools`, gated) | apt `ffmpeg` (gated) | video thumbnails |
| ImageMagick | `imagemagick` (`media_tools`, gated) | apt `imagemagick` (gated) | HEIC / JPEG-XL / fonts |
| pandoc | `pandoc` (already in `devtools`) | apt `pandoc` | EPUB text |
| glow | `glow` (already in `devtools`) | GitHub release → `~/.local/bin` (x86_64/arm64) | rendered Markdown |
| calibre (`ebook-meta`) | `calibre` cask — opt-in `installCalibre` | apt `calibre` — opt-in | Kindle .mobi/.azw/.azw3 metadata |

## Gotchas

- **Rename / shell popup with `rgb:…` junk on image hover** → the chafa OSC-query leak under
  tmux/zellij; fixed here by the `--probe off` shim — see [above](#chafa-probe-leak).
- **Ubuntu ImageMagick is v6.** apt ships ImageMagick 6 (no unified `magick`; weak HEIC), so HEIC/font
  previews may not work on Ubuntu even with `installMediaTools=true`. yazi wants **≥7.1.1**; v7 needs a
  PPA or source build (out of scope). macOS brew ImageMagick is v7 → fine.
- **Video/HEIC need `installMediaTools`.** ffmpeg + ImageMagick are opt-in. If mp4 thumbnails or HEIC
  previews are blank, re-run init with `installMediaTools=true` (or install ffmpeg/imagemagick by
  hand). Everything else in the baseline works without it.
- **resvg on Linux is best-effort.** No apt package → the role tries Linuxbrew then a one-time
  `cargo install resvg`. If neither is available, SVG simply previews as raw text — non-fatal.
- **Lowercase globs.** The `*.md` / `*.epub` / `*.dmg` / `*.mobi` rules match lowercase extensions;
  `Book.EPUB` won't fire (yazi's built-ins are mime-based and unaffected).
- **Markdown preview is rendered, not raw.** `.md` goes through glow, so you see formatted output
  rather than the source markup — press `Enter` to open the raw file in `$EDITOR`. See
  [above](#markdown-glow).
- **Kindle previews are metadata, not text.** `.mobi`/`.azw`/`.azw3` show the book's title / author /
  description (via calibre `ebook-meta`), not the prose — there's no fast headless mobi/azw text
  renderer. Needs calibre (the `installCalibre` prompt, or a manual install). EPUB gets full text (pandoc).
- **Image-only pptx → slide thumbnail.** A deck whose slides are full-page images has no text for
  markitdown to extract, so view-office renders the first embedded slide image with chafa instead of a
  list of `![](imageN)`. It's detected cheaply by peeking at the slide XML with 7-Zip. See
  [office-viewers.md](office-viewers.md).
- **chafa is a fallback, not a downgrade to avoid.** ascii-art is the correct behavior in a
  non-graphics terminal — see [above](#which-terminal-gets-crisp-images-vs-ascii-art).
- **Large image → `Image size exceeds limit`.** yazi's decode bound (`[tasks] image_bound`), not the
  terminal; raised to `[30000, 30000]` here — see [above](#image-size-limit).

## Where things live

| Surface | Path |
|---|---|
| Baseline tool install (chafa/poppler/7zip/resvg) | `dot_ansible/roles/devtools/tasks/main.yml` |
| chafa `--probe off` shim (fixes the rename/shell popup) | `dot_dotfiles/bin/executable_chafa` |
| Media tool install (ffmpeg/ImageMagick, gated) | `dot_ansible/roles/media_tools/tasks/main.yml` |
| calibre install (opt-in `installCalibre`) | `dot_ansible/roles/devtools/tasks/main.yml` |
| EPUB / Kindle / dmg / Markdown previewer rules | `dot_config/yazi/yazi.toml` `[plugin] prepend_previewers` |
| Kindle metadata dispatcher | `dot_dotfiles/bin/executable_view-ebook` (+ 56_view_ebook_completion.*) |
| pptx image-only thumbnail | `dot_dotfiles/bin/executable_view-office` (`render_pptx`) |
| yazi install | `dot_ansible/roles/devtools/tasks/main.yml` (`# --- yazi ---`) |
| tmux image passthrough | `dot_config/tmux/common.conf.tmpl` (`allow-passthrough on`) |

## See also

- [Data viewers](data-viewers.md) — the csv/parquet/xlsx/sqlite/feather table-preview stack (duckdb.yazi).
- [Office viewers](office-viewers.md) — the docx/pptx/legacy/ODF stack + the shared `ya pkg` / `piper.yazi` mechanism.
- [tool-managers.md § Tool index](../this_repo/tool-managers.md#tool-index-az) — where chafa / poppler / sevenzip / resvg come from per OS.
- yazi upstream: [installation deps](https://yazi-rs.github.io/docs/installation/), [image preview](https://yazi-rs.github.io/docs/image-preview/).
