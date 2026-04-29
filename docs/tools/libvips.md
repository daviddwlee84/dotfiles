# libvips — high-throughput image processing

[libvips](https://www.libvips.org/) is a streaming image-processing library tuned for **large** and **many** images: low memory, partial reads, parallel pipelines. Where ImageMagick loads each image fully into RAM, libvips streams pixels through the operations it actually needs. At ~1k+ images or for any image bigger than a few hundred MB, it's the right tool. Bundled here under `installMediaTools=true` together with [ffmpeg](ffmpeg.md), [ImageMagick](imagemagick.md), and [ExifTool](exiftool.md).

- **Install**:
  - macOS — Homebrew (`brew install vips`), managed by `dot_ansible/roles/media_tools/tasks/main.yml` when `installMediaTools=true`.
  - Linux — apt (`sudo apt install libvips-tools`), same role / same flag. The `-tools` package ships the CLIs (`vips`, `vipsthumbnail`, `vipsedit`, `vipsheader`); the bare `libvips42` package is library-only.
- **Verify**: `vips --version` and `vipsthumbnail --version`.
- **Status in this repo**: opt-in via `installMediaTools=true`. No automation calls into it yet — it's there for when ImageMagick chokes.

---

## When to pick libvips over ImageMagick

| Situation | Pick |
|---|---|
| Single image, complex composite / annotate | [ImageMagick](imagemagick.md) |
| One-off resize / crop | Either; ImageMagick is more familiar |
| Batch of 1k+ images | **libvips** (often 5–10× faster, 1/10 the RAM) |
| Image > 500 MB / gigapixel scans | **libvips** (ImageMagick may OOM) |
| Server-side thumbnail pipeline | **libvips** (`vipsthumbnail` is purpose-built) |
| Interactive ad-hoc tweaks | [ImageMagick](imagemagick.md) (better one-liners) |

The two complement each other — having both installed is the default here.

---

## `vipsthumbnail` — the killer app

Generate thumbnails from large images without ever loading the full pixel buffer:

```bash
# Single image — max 1280px on the long edge
vipsthumbnail input.jpg --size 1280 -o output.jpg

# Pin a width (height auto)
vipsthumbnail input.jpg --size '1280x'

# Pin a height (width auto)
vipsthumbnail input.jpg --size 'x720'

# Output template — write next to source as <name>_tn.jpg
vipsthumbnail *.jpg --size 320 -o '%s_tn.jpg'

# Custom output dir
vipsthumbnail *.jpg --size 320 -o 'thumbs/%s.jpg[Q=85]'
```

`%s` in the output template expands to the input basename (without extension). The `[Q=85]` suffix sets JPEG quality.

For raw camera files / TIFFs / WebP / HEIC — vipsthumbnail picks the right loader automatically and only decodes the region needed for the target size.

---

## `vips` — the operation runner

```bash
# Resize (preserves aspect)
vips resize input.jpg output.jpg 0.5     # half size

# Crop — left, top, width, height
vips crop input.jpg output.jpg 100 50 800 600

# Rotate
vips rot input.jpg output.jpg d90        # 90° clockwise; d180 / d270

# Flip
vips flip input.jpg output.jpg horizontal

# Strip ICC + metadata on save (smaller files)
vips copy input.jpg output.jpg[strip,Q=85]
```

Saver options (`Q=...`, `strip`, `interlace`, `optimize_coding`, `subsample_mode=...`) go in `[brackets]` after the output path. Loaders use the same syntax (`input.tif[page=2]` for multi-page TIFFs).

---

## Format-specific savers

```bash
# JPEG with custom quality
vips copy input.png output.jpg[Q=80,optimize_coding,strip]

# WebP (smaller, modern)
vips copy input.png output.webp[Q=80,strip,effort=4]

# AVIF (smallest, slowest encode)
vips copy input.png output.avif[Q=50,effort=6]

# Tiled / pyramid TIFF (zoomable on viewers like OpenSeadragon)
vips copy input.jpg output.tif[tile,pyramid,compression=jpeg,Q=85]
```

`vips --vips-help-loaders` and `--vips-help-savers` enumerate the full list.

---

## Inspect

```bash
vipsheader input.jpg                     # one-line header
vipsheader -a input.jpg                  # all tags
vipsheader -f width input.jpg            # single field
vipsheader -f vips-loader input.jpg      # which loader was picked
```

---

## Pipelines

libvips' streaming model means pipelines stay memory-bounded:

```bash
# Resize then jpeg → smaller file, never loads full image
vips resize input.tif output.jpg[Q=85] 0.25

# Sequential mode for huge files — reads top-to-bottom, can't seek backwards
vipsthumbnail huge_scan.tif --size 2000 -o thumb.jpg --intent perceptual
```

For Python (and other binding) usage see <https://www.libvips.org/API/current/python.html>. The CLI covers most batch needs.

---

## Watch out

- **No `convert input output`** — every operation has a verb (`resize`, `crop`, `rot`, …). Run `vips list classes` to enumerate.
- **Saver options live in brackets** — `output.jpg Q=85` does not work; `output.jpg[Q=85]` does. Easy to miss.
- **Color profiles** — by default vips preserves embedded ICC profiles. Pass `[strip]` if downstream consumers don't handle them, or convert with `vips icc_transform` first.
- **Sequential mode lock-in** — `--intent perceptual` etc. on `vipsthumbnail` switch to streaming mode. Random-access ops like center crop won't work in that mode; use `vips` for those.

---

## See also

- [ImageMagick](imagemagick.md) — the everyday counterpart; pick libvips only when scale demands it
- [ExifTool](exiftool.md) — libvips' `[strip]` is all-or-nothing; for surgical metadata edits use exiftool
- [ffmpeg](ffmpeg.md) — for moving images / video frames
- Upstream API reference: <https://www.libvips.org/API/current/>
- Performance notes & benchmarks: <https://github.com/libvips/libvips/wiki/Speed-and-memory-use>
