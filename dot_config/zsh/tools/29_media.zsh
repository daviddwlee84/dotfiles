# 29_media.zsh - ffmpeg helper functions (compress / extract / 16k-mono)

# Only load when ffmpeg is on PATH (installMediaTools=true, or hand-installed).
command -v ffmpeg &>/dev/null || return 0

# Compress an MP4 with x264 CRF 28 (smaller; tweak CRF inline for quality).
# Output: <name>_compressed.mp4 next to the input.
compress-video() {
    emulate -L zsh
    [[ -f "$1" ]] || { echo "usage: compress-video <input>" >&2; return 2 }
    ffmpeg -i "$1" -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 128k "${1:r}_compressed.mp4"
}

# Extract audio without re-encoding. Output is .m4a (AAC sources keep AAC).
extract-audio() {
    emulate -L zsh
    [[ -f "$1" ]] || { echo "usage: extract-audio <input>" >&2; return 2 }
    ffmpeg -i "$1" -vn -c:a copy "${1:r}.m4a"
}

# Re-encode to 16 kHz mono WAV — Whisper / faster-whisper / wav2vec input format.
to-wav16k() {
    emulate -L zsh
    [[ -f "$1" ]] || { echo "usage: to-wav16k <input>" >&2; return 2 }
    ffmpeg -i "$1" -ar 16000 -ac 1 "${1:r}_16k.wav"
}
