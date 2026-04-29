# ImageMagick — image swiss army knife

[ImageMagick](https://imagemagick.org/) is the de-facto CLI for single-image and small-batch image transforms — convert, resize, crop, composite, annotate, filter. Bundled here under `installMediaTools=true` together with [ffmpeg](ffmpeg.md), [ExifTool](exiftool.md), and [libvips](libvips.md).

- **Install**:
  - macOS — Homebrew (`brew install imagemagick`), v7 with the unified `magick` binary. Managed by `dot_ansible/roles/media_tools/tasks/main.yml` when `installMediaTools=true`.
  - Linux — apt (`sudo apt install imagemagick`). Ubuntu 24.04 still ships **v6**, which exposes the legacy per-tool commands (`convert`, `identify`, `mogrify`, `composite`, …) instead of the unified `magick`. Same role / same flag.
- **Verify**: `magick --version` (v7) or `convert --version` (v6).
- **Status in this repo**: opt-in via `installMediaTools=true`. No automation calls into ImageMagick yet — it's there for ad-hoc image work.

---

## v6 vs v7 — which command?

ImageMagick 7 unifies all the legacy executables behind a single `magick` entrypoint:

```bash
# v7 (macOS Homebrew)
magick input.png -resize 1280x output.png

# v6 (Ubuntu 24.04 apt)
convert input.png -resize 1280x output.png
```

`magick` accepts `magick convert ...`, `magick identify ...`, etc., for backward compatibility. To write portable scripts, prefer `magick` and fall back to `convert`:

```bash
IM=$(command -v magick || command -v convert)
"$IM" input.png -resize 1280x output.png
```

The rest of this page uses `magick`; mentally substitute `convert` on Ubuntu 24.04.

---

## Common transforms

```bash
# Inspect
magick identify input.png                    # one-line summary
magick identify -verbose input.png | head -40

# Resize (preserve aspect)
magick input.png -resize 1280x output.png    # max width 1280
magick input.png -resize 1280x720 output.png # fit inside 1280×720

# Crop
magick input.png -crop 800x600+100+50 output.png   # WIDTHxHEIGHT+X+Y

# Quality / format
magick input.jpg -quality 85 output.jpg
magick input.png -background white -alpha remove output.jpg   # PNG → JPG, fill alpha
```

`-resize 1280x` keeps aspect; `-resize 1280x720!` (with `!`) forces exact dimensions and may distort.

---

## Batch resize / convert

```bash
mkdir -p resized
for f in *.jpg; do
  magick "$f" -resize 1280x "resized/$f"
done
```

For thousands of files, see [libvips](libvips.md) — `vipsthumbnail` is 5–10× faster and uses a fraction of the memory.

`mogrify` (v6) / `magick mogrify` (v7) edits in place — fast but destructive:

```bash
magick mogrify -resize 1280x -path resized/ *.jpg     # writes to resized/, leaves originals alone
magick mogrify -resize 1280x *.jpg                    # OVERWRITES the originals
```

---

## Compositing

```bash
# Overlay logo bottom-right with 20px margin
magick input.png logo.png \
  -gravity southeast -geometry +20+20 \
  -composite output.png

# Add solid border
magick input.png -bordercolor white -border 20 output.png

# Round corners (alpha mask trick)
magick input.png \
  \( +clone -alpha extract \
     -draw 'fill black polygon 0,0 0,15 15,0 fill white circle 15,15 15,0' \
     \( +clone -flip \) -compose Multiply -composite \
     \( +clone -flop \) -compose Multiply -composite \
  \) -alpha off -compose CopyOpacity -composite rounded.png
```

Compositing is where ImageMagick beats ffmpeg — the syntax is dense but designed for one-off image work.

---

## Annotate

```bash
# Caption under an image
magick input.png \
  -gravity south -background "#00000088" -fill white \
  -splice 0x40 -annotate +0+10 'Caption text' \
  output.png
```

For repeatable styling, save a config file or wrap in a shell function.

---

## Format conversion shortcuts

```bash
magick input.heic output.jpg     # HEIC → JPG (needs libheif support; check `magick -list format`)
magick input.svg -density 300 output.png   # SVG → high-DPI PNG
magick *.jpg output.pdf          # JPGs → multi-page PDF
magick input.pdf[0] cover.png    # First page of PDF → PNG (needs ghostscript)
```

PDF support depends on Ghostscript being installed. macOS Homebrew pulls it as a dep; on Ubuntu install separately (`sudo apt install ghostscript`).

---

## Watch out

- **PDF / PostScript policy** — recent Debian / Ubuntu builds ship with `/etc/ImageMagick-6/policy.xml` blocking PDF reads (CVE-2018-16509). If `magick input.pdf cover.png` errors with "not authorized", edit the policy or convert via `pdftoppm` first.
- **Memory limits** — same policy.xml caps memory / area / disk. For big batches, prefer libvips.
- **Determinism** — pin font, density, colorspace via flags so two runs produce byte-identical output. Useful for diffable visual tests.

---

## See also

- [libvips](libvips.md) — when ImageMagick chokes on memory or speed at scale (>1k images)
- [ExifTool](exiftool.md) — preserves / strips EXIF metadata that ImageMagick can blow away on conversion
- [ffmpeg](ffmpeg.md) — for moving images (frame extraction, GIFs, screen recording)
- [Freeze](freeze.md) — for code → image specifically (don't reach for `magick` for that)
- Upstream usage: <https://imagemagick.org/script/command-line-options.php>
