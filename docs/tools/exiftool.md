# ExifTool — image / video metadata reader & editor

[ExifTool](https://exiftool.org/) is the reference CLI for reading, writing, and stripping metadata in images, videos, and audio (EXIF, IPTC, XMP, GPS, MakerNotes, …). Bundled here under `installMediaTools=true` together with [ffmpeg](ffmpeg.md), [ImageMagick](imagemagick.md), and [libvips](libvips.md).

- **Install**:
  - macOS — Homebrew (`brew install exiftool`), managed by `dot_ansible/roles/media_tools/tasks/main.yml` when `installMediaTools=true`.
  - Linux — apt (`sudo apt install libimage-exiftool-perl`), same role / same flag. The package name reflects that exiftool is a Perl script + module suite — that's not a typo.
- **Verify**: `exiftool -ver`.
- **Status in this repo**: opt-in via `installMediaTools=true`. No automation hooks into it yet.

---

## Read

```bash
# Human-readable summary
exiftool image.jpg

# Specific tags only
exiftool -DateTimeOriginal -GPSPosition -Make -Model image.jpg

# JSON output (pipeline-friendly)
exiftool -json image.jpg | jq

# Recurse a directory tree
exiftool -r ~/Photos

# A specific category
exiftool -GPS:all video.mov
```

---

## Strip metadata (privacy)

Photos straight off a phone leak GPS coordinates, camera serial, owner name, app fingerprint. Before sharing publicly:

```bash
# Strip everything (creates image.jpg_original backup)
exiftool -all= image.jpg

# Strip everything, no backup
exiftool -all= -overwrite_original image.jpg

# Strip only the privacy-sensitive tags (preserve EXIF camera tags)
exiftool -GPS:all= -Make= -Model= -SerialNumber= image.jpg

# Recursive scrub
exiftool -all= -overwrite_original -r ~/Photos
```

The `_original` backup is exiftool's safety net — without `-overwrite_original` you'll see `IMG_1234.jpg` and `IMG_1234.jpg_original` side-by-side. Useful for one-offs, painful for batches; pick the variant that matches your use case.

> **Privacy reminder** — same warning as the [Freeze](freeze.md) "don't snapshot secrets" note: scrub before publishing. Public pages are crawled, screenshotted, and archived; what you upload today is downloadable forever.

---

## Write / edit

```bash
# Set a single tag
exiftool -Artist="Da-Wei Lee" image.jpg

# Fix a wrong capture timestamp (drift correction)
exiftool -AllDates+="0:0:0 1:0:0" *.jpg     # shift +1 hour

# Stamp GPS from numeric coords
exiftool -GPSLatitude=25.0330 -GPSLongitude=121.5654 -GPSLatitudeRef=N -GPSLongitudeRef=E image.jpg

# Copy metadata from one file to another
exiftool -TagsFromFile source.jpg target.jpg
exiftool -TagsFromFile source.jpg -all:all target.jpg     # everything
```

Tag names are case-insensitive. Run `exiftool -listx 2>&1 | head -50` for the full universe.

---

## Rename / organize by metadata

```bash
# Rename to YYYYMMDD_HHMMSS.jpg using EXIF DateTimeOriginal
exiftool '-FileName<DateTimeOriginal' -d '%Y%m%d_%H%M%S.%%e' *.jpg

# Move into year/month folders
exiftool '-Directory<DateTimeOriginal' -d '%Y/%m' -r ~/Photos

# Dry run first — exiftool actually moves files, not just prints
exiftool '-FileName<DateTimeOriginal' -d '%Y%m%d_%H%M%S.%%e' -if 'not $self{Directory_changed}' --testname *.jpg
```

`%%e` is exiftool's literal `%e` — the original extension (lowercased). Single `%` is `strftime`.

---

## Pipelines

```bash
# Sort photos with no GPS to the top — useful triage
exiftool -p '$GPSPosition $FileName' -if '$GPSPosition eq ""' -r ~/Photos

# CSV export for a spreadsheet
exiftool -csv -DateTimeOriginal -Make -Model -GPSPosition -r ~/Photos > photos.csv

# Diff metadata between two files
diff <(exiftool a.jpg) <(exiftool b.jpg)
```

---

## Watch out

- **Default backups eat disk** — `_original` files accumulate fast. Use `-overwrite_original` once you trust the operation, or sweep with `find . -name '*_original' -delete` after.
- **Some formats only support a subset of tags** — exiftool will silently skip writes that the container doesn't support. Add `-v3` if you need to see what was actually written.
- **GPS without a ref direction** — `-GPSLatitude=25.0330` alone defaults to North; for southern hemisphere you need `-GPSLatitudeRef=S` AND a positive number (or use the `-XMP-exif:GPSLatitude` API which accepts signed). Easy footgun.
- **Sidecar XMP** — for raw camera files, write to `IMG_1234.xmp` instead of mutating the raw. `exiftool -o %d%f.xmp image.cr2` creates a sidecar.

---

## See also

- [ImageMagick](imagemagick.md) — strips most metadata on `magick input.jpg output.jpg`; pair with exiftool's `-TagsFromFile` to preserve what you want
- [ffmpeg](ffmpeg.md) — also reads container metadata (`ffprobe`); use exiftool for finer-grained edits or for stills
- [Freeze](freeze.md) — privacy callout applies to screenshots too
- Upstream tag reference: <https://exiftool.org/TagNames/index.html>
