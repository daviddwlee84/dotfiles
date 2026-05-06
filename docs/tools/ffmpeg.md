# ffmpeg — audio / video swiss army knife

[FFmpeg](https://ffmpeg.org/) is the universal audio/video toolchain that almost every higher-level tool (vhs, OBS, video editors, ASR pipelines) calls under the hood. Bundled here under `installMediaTools=true` together with [ImageMagick](imagemagick.md), [ExifTool](exiftool.md), and [libvips](libvips.md).

- **Install**:
  - macOS — Homebrew (`brew install ffmpeg`), managed by `dot_ansible/roles/media_tools/tasks/main.yml` when `installMediaTools=true`.
  - Linux — apt (`sudo apt install ffmpeg`), same role / same flag. Skipped automatically when `noRoot=true` (the apt block carries `tags: [sudo]`).
- **Verify**: `ffmpeg -version | head -1` and `ffprobe -version | head -1`.
- **Status in this repo**: opt-in via `installMediaTools=true`. Three zsh helpers (`compress-video`, `extract-audio`, `to-wav16k`) ship at [`dot_config/zsh/tools/29_media.zsh`](../../dot_config/zsh/tools/29_media.zsh) — see [docs/shells/aliases.md → Media / AV](../shells/aliases.md#media--av). Also satisfies the runtime dep that [`vhs`](vhs.md) needs to record.

---

## Common conversions

```bash
# Container conversion (.mov / .mkv / .webm → .mp4)
ffmpeg -i input.mov output.mp4

# Re-encode with x264 + AAC
ffmpeg -i input.mov -c:v libx264 -c:a aac output.mp4
```

`-c copy` skips re-encoding entirely when the codec is already compatible — orders of magnitude faster but the source streams must be valid for the target container.

---

## Compression — CRF cheatsheet

```bash
# Smaller MP4 with x264 (preset slow trades CPU for size).
ffmpeg -i input.mp4 -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 128k output.mp4
```

| `-crf` | Use for |
|---|---|
| 18 | Visually lossless (archive masters) |
| 23 | Default — good quality, reasonable size |
| 28 | Decent quality, ~½ the size of CRF 23 (the `compress-video` zsh helper uses this) |
| 32 | Aggressive — visible artifacts but tiny files |

`-preset` knobs (`ultrafast` → `placebo`) trade encode time for compression efficiency at the same CRF.

---

## Audio

```bash
# Strip video, keep audio without re-encoding (fastest)
ffmpeg -i input.mp4 -vn -c:a copy output.m4a

# Re-encode to a clean format
ffmpeg -i input.wav output.mp3
ffmpeg -i input.flac output.m4a

# Whisper / faster-whisper / wav2vec want 16 kHz mono WAV
ffmpeg -i input.m4a -ar 16000 -ac 1 output_16k.wav
```

The last two patterns are wrapped by [`extract-audio`](../shells/aliases.md#media--av) and [`to-wav16k`](../shells/aliases.md#media--av).

---

## Trim / cut

```bash
# Fast cut (stream-copy) — keyframe-aligned, may overshoot by a fraction of a sec
ffmpeg -ss 00:00:30 -i input.mp4 -t 10 -c copy clip.mp4

# Frame-accurate cut (re-encodes)
ffmpeg -ss 00:00:30 -i input.mp4 -t 10 clip.mp4
```

Place `-ss` *before* `-i` for fast input-side seek; place it *after* `-i` for accurate output-side seek (slower).

---

## Concat

```bash
# files.txt:
#   file 'part1.mp4'
#   file 'part2.mp4'
ffmpeg -f concat -safe 0 -i files.txt -c copy output.mp4
```

All inputs must share codec + resolution + framerate. If they don't, re-encode first or use `-filter_complex concat=n=N:v=1:a=1`.

---

## Frames ↔ video

```bash
# Pull every Nth second as a PNG
ffmpeg -i input.mp4 -vf fps=1 frame_%04d.png

# One frame at a specific timestamp
ffmpeg -ss 00:01:23 -i input.mp4 -frames:v 1 screenshot.png

# Image sequence → video (e.g. matplotlib export, ML training viz)
ffmpeg -framerate 30 -i frame_%04d.png -c:v libx264 -pix_fmt yuv420p output.mp4
```

`-pix_fmt yuv420p` is the safest pixel format for browsers / Slack / iOS Quick Look — without it, x264 may pick a 4:4:4 variant that some players refuse.

---

## GIF (and why MP4 is usually better)

```bash
# Quick GIF
ffmpeg -i input.mp4 -vf "fps=12,scale=640:-1" output.gif

# Higher-quality GIF (palettegen → paletteuse, two-pass)
ffmpeg -i input.mp4 -vf "fps=12,scale=640:-1,palettegen" /tmp/palette.png
ffmpeg -i input.mp4 -i /tmp/palette.png -lavfi "fps=12,scale=640:-1 [v]; [v][1:v] paletteuse" output.gif
```

GIFs are 5–20× larger than equivalent MP4/WebM at similar visual quality. Prefer MP4 unless the destination requires GIF (some chat platforms still do).

---

## Inspect

```bash
ffprobe input.mp4
ffprobe -v error -show_format -show_streams input.mp4         # structured
ffprobe -v error -show_streams -of json input.mp4 | jq        # JSON pipeline
```

`ffprobe` ships in the same package — no separate install.

---

## Subtitles

```bash
# Soft (mux) — embeds .srt as a track, players can toggle it
ffmpeg -i input.mp4 -i subtitle.srt -c copy output.mkv

# Hard (burn-in) — bakes text into pixels, no toggling
ffmpeg -i input.mp4 -vf subtitles=subtitle.srt output.mp4
```

Soft subs are smaller and editable; hard subs survive platforms that strip subtitle tracks.

---

## See also

- [VHS](vhs.md) — terminal recorder; depends on ffmpeg at runtime to write GIF / MP4
- [ImageMagick](imagemagick.md) — sibling tool for **stills** (single-image transforms)
- [ExifTool](exiftool.md) — strip metadata from the videos you produce here
- [libvips](libvips.md) — when batch image work outgrows ImageMagick
- [docs/shells/aliases.md → Media / AV](../shells/aliases.md#media--av) — the three shipped helper functions
- Upstream cheatsheet: <https://trac.ffmpeg.org/wiki>
