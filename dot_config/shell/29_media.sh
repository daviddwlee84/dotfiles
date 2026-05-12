# 29_media.sh - ffmpeg + ImageMagick helpers (shared bash + zsh).
# Moved from dot_config/zsh/tools/29_media.zsh. Zsh-isms replaced:
#   ${1:r}  (root, drop extension)  → ${1%.*}
#   ${1:e}  (extension only)        → ${1##*.}
#   emulate -L zsh                  → gated on $ZSH_VERSION

# Load if any media tool is on PATH (installMediaTools=true, or hand-installed).
# Each function self-checks for its specific dep so partial installs work.
command -v ffmpeg &>/dev/null \
    || command -v magick &>/dev/null \
    || command -v convert &>/dev/null \
    || return 0

# === ffmpeg helpers (video / audio) =========================================

# Compress an MP4 with x264 CRF 28 (smaller; tweak CRF inline for quality).
# Output: <name>_compressed.mp4 next to the input.
compress-video() {
    [ -n "$ZSH_VERSION" ] && emulate -L zsh
    [ -f "$1" ] || { echo "usage: compress-video <input>" >&2; return 2; }
    ffmpeg -i "$1" -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 128k "${1%.*}_compressed.mp4"
}

# Extract audio without re-encoding. Output is .m4a (AAC sources keep AAC).
extract-audio() {
    [ -n "$ZSH_VERSION" ] && emulate -L zsh
    [ -f "$1" ] || { echo "usage: extract-audio <input>" >&2; return 2; }
    ffmpeg -i "$1" -vn -c:a copy "${1%.*}.m4a"
}

# Re-encode to 16 kHz mono WAV — Whisper / faster-whisper / wav2vec input format.
to-wav16k() {
    [ -n "$ZSH_VERSION" ] && emulate -L zsh
    [ -f "$1" ] || { echo "usage: to-wav16k <input>" >&2; return 2; }
    ffmpeg -i "$1" -ar 16000 -ac 1 "${1%.*}_16k.wav"
}

# === ImageMagick helpers (image) ============================================

# Resolve `magick` (v7) or `convert` (v6) into $REPLY. Returns 1 if neither.
_29_media_im() {
    REPLY=$(command -v magick) && return 0
    REPLY=$(command -v convert) && return 0
    echo "ImageMagick not found (install via installMediaTools=true)" >&2
    return 1
}

# compress-image <input> [<target_mb=1>]
# Re-encode to JPEG under <target_mb> MB. Uses ImageMagick's
# `-define jpeg:extent=NMB`, which iterates quality internally — single shot,
# no manual binary search. Alpha is flattened to white (PNG/WebP screenshots).
# Output: <name>_<mb>mb.jpg
compress-image() {
    [ -n "$ZSH_VERSION" ] && emulate -L zsh
    [ -f "$1" ] || { echo "usage: compress-image <input> [<target_mb=1>]" >&2; return 2; }
    local IM
    _29_media_im || return 1
    IM=$REPLY
    local mb="${2:-1}"
    local out="${1%.*}_${mb}mb.jpg"
    "$IM" "$1" -auto-orient -strip -background white -alpha remove -alpha off \
        -define "jpeg:extent=${mb}MB" "$out"
    [ -f "$out" ] && echo "→ $out ($(du -h "$out" | cut -f1))"
}

# resize-image <input> <width_px>
# Resize so width = <width_px> (preserves aspect). Output keeps source format.
# Output: <name>_<width>w.<ext>
resize-image() {
    [ -n "$ZSH_VERSION" ] && emulate -L zsh
    [ -f "$1" ] && [ -n "$2" ] || { echo "usage: resize-image <input> <width_px>" >&2; return 2; }
    local IM
    _29_media_im || return 1
    IM=$REPLY
    local out="${1%.*}_${2}w.${1##*.}"
    "$IM" "$1" -auto-orient -resize "${2}x" "$out"
    [ -f "$out" ] && echo "→ $out ($(du -h "$out" | cut -f1))"
}

# === gum-driven interactive launcher ========================================

if command -v gum &>/dev/null; then
    # media-pick: gum file picker → action chooser → (optional) param input.
    # No-args entrypoint that wires every helper above for non-CLI users.
    media-pick() {
        [ -n "$ZSH_VERSION" ] && emulate -L zsh
        local file action
        file=$(gum file --no-permissions) || return 0
        [ -f "$file" ] || { echo "not a file: $file" >&2; return 2; }
        action=$(gum choose \
            "compress-video" \
            "compress-image (1 MB)" \
            "compress-image (custom MB)" \
            "resize-image (custom width)" \
            "extract-audio" \
            "to-wav16k") || return 0
        case "$action" in
            "compress-video")            compress-video "$file" ;;
            "compress-image (1 MB)")     compress-image "$file" 1 ;;
            "compress-image (custom MB)")
                local mb
                mb=$(gum input --placeholder "target MB (e.g. 2)" --value 2) || return 0
                compress-image "$file" "$mb"
                ;;
            "resize-image (custom width)")
                local w
                w=$(gum input --placeholder "max width px (e.g. 1280)" --value 1280) || return 0
                resize-image "$file" "$w"
                ;;
            "extract-audio")             extract-audio "$file" ;;
            "to-wav16k")                 to-wav16k "$file" ;;
        esac
    }
fi
