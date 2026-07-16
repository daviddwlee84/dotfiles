# Yazi Preview Coverage

Maximize what the [yazi](tmux/README.md) file manager can preview on hover — **images, PDF, video,
SVG, archives, ebooks, dmg**, on top of the tabular/office stacks documented in
[data-viewers.md](data-viewers.md) and [office-viewers.md](office-viewers.md).

The catch: yazi's **built-in** previewers (images / PDF / video / SVG / standard archives) are *not*
wired in `dot_config/yazi/yazi.toml` — yazi ships them internally and **shells out to external
binaries at runtime**. If those binaries aren't installed, the hover pane shows an error
(`failed to spawn chafa`) or bare file-type classification. So "expanding coverage" is mostly a
**tool-install** job (a few ansible-managed binaries), plus two tiny config rules for the container
formats yazi ignores by default.

## TL;DR — coverage matrix

| File type | Preview | Powered by | Tier |
|---|---|---|---|
| png / jpg / webp / gif / bmp | image (or unicode-art) | yazi built-in → **chafa** to display | baseline |
| **PDF** | first page as image | yazi built-in → **poppler** (`pdftoppm`) + chafa | baseline |
| **SVG** | rendered image | yazi built-in → **resvg** + chafa | baseline |
| archives: zip / tar / gz / 7z / rar (+ zip-based apk / jar / whl / xpi) | file listing | yazi built-in → **7-Zip** | baseline |
| **dmg** | file listing | piper → **7-Zip** (`*.dmg` rule) | baseline |
| **EPUB** | text | piper → **pandoc** (`*.epub` rule) | baseline |
| video: mp4 / mkv / mov … | thumbnail | yazi built-in → **ffmpeg** + chafa | media (gated) |
| HEIC / JPEG-XL / fonts | image / sample | yazi built-in → **ImageMagick ≥7.1.1** + chafa | media (gated) |
| csv / tsv / parquet / xlsx / db / sqlite / feather | table | duckdb.yazi + fallbacks | plugin — see [data-viewers.md](data-viewers.md) |
| docx / pptx / legacy / ODF | rendered text | view-office (doxx / markitdown / LibreOffice) | plugin — see [office-viewers.md](office-viewers.md) |
| txt / json / md / source | text (+ syntax) | yazi built-in / `bat` | always |

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

### Unicode-art vs crisp inline images

chafa gives **universal ASCII/ANSI-art** previews that work everywhere — over tmux, over SSH, in any
terminal. For crisp *inline* images, run yazi in a graphics-capable terminal
(**Ghostty / Kitty / iTerm2 / WezTerm / Konsole / foot / Ghostty**); yazi auto-upgrades the adapter,
no config change. Over tmux the terminal must support Kitty-graphics passthrough — this repo already
sets `allow-passthrough on` (`dot_config/tmux/common.conf.tmpl`), but the older `KgpOld` protocol
variant doesn't work under tmux and Sixel needs a `--enable-sixel` tmux build. If you only ever get
ascii-art, that's the terminal/tmux graphics story, **not** a missing tool — chafa is doing its job.
See yazi's [image-preview docs](https://yazi-rs.github.io/docs/image-preview/).

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

## The two config rules (EPUB + dmg)

Everything above except EPUB and dmg is pure tool-install — yazi's built-ins handle the routing. Those
two container mimes (`application/epub+zip`, `application/x-apple-diskimage`) are **not** in yazi's
built-in archive set, so `dot_config/yazi/yazi.toml` adds them via [`piper.yazi`](office-viewers.md#the-ya-pkg-plugin-mechanism):

```toml
{ url = "*.epub", run = 'piper -- pandoc -f epub -t plain "$1" 2>/dev/null | head -n 500' },
{ url = "*.dmg",  run = 'piper -- ( 7zz l "$1" 2>/dev/null || 7z l "$1" 2>/dev/null ) | head -n 200' },
```

- `2>/dev/null` is **load-bearing** — piper renders any stderr as an error preview.
- `7zz || 7z` covers macOS `sevenzip` (`7zz`) vs Linux `p7zip-full` (`7z`).
- **No rule needed** for `.zip` / `.tar.*` / `.7z` / `.rar` or zip-based `.apk` / `.jar` / `.whl` /
  `.xpi` — yazi's built-in archive previewer lists them for free once 7-Zip is installed.

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
- **Lowercase globs.** The `*.epub` / `*.dmg` rules match lowercase extensions; `Book.EPUB` won't fire
  (yazi's built-ins are mime-based and unaffected).
- **chafa is a fallback, not a downgrade to avoid.** ascii-art is the correct behavior in a
  non-graphics terminal — see [above](#unicode-art-vs-crisp-inline-images).

## Where things live

| Surface | Path |
|---|---|
| Baseline tool install (chafa/poppler/7zip/resvg) | `dot_ansible/roles/devtools/tasks/main.yml` |
| chafa `--probe off` shim (fixes the rename/shell popup) | `dot_dotfiles/bin/executable_chafa` |
| Media tool install (ffmpeg/ImageMagick, gated) | `dot_ansible/roles/media_tools/tasks/main.yml` |
| EPUB + dmg previewer rules | `dot_config/yazi/yazi.toml` `[plugin] prepend_previewers` |
| yazi install | `dot_ansible/roles/devtools/tasks/main.yml` (`# --- yazi ---`) |
| tmux image passthrough | `dot_config/tmux/common.conf.tmpl` (`allow-passthrough on`) |

## See also

- [Data viewers](data-viewers.md) — the csv/parquet/xlsx/sqlite/feather table-preview stack (duckdb.yazi).
- [Office viewers](office-viewers.md) — the docx/pptx/legacy/ODF stack + the shared `ya pkg` / `piper.yazi` mechanism.
- [tool-managers.md § Tool index](../this_repo/tool-managers.md#tool-index-az) — where chafa / poppler / sevenzip / resvg come from per OS.
- yazi upstream: [installation deps](https://yazi-rs.github.io/docs/installation/), [image preview](https://yazi-rs.github.io/docs/image-preview/).
