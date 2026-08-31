# 32_summarize.sh - summarize CLI helpers (shared by zsh/bash)
# https://github.com/steipete/summarize
#
# Output language/length come from the managed ~/.summarize/config.json overlay
# (dot_summarize/modify_config.json), so plain `summarize <url>` already answers in
# 繁體中文. These wrappers only add per-source prompt presets on top; override the
# language per call with `--language en`.

# Check if summarize is installed
command -v summarize >/dev/null 2>&1 || return 0

SUMMARIZE_PROMPT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/summarize/prompts"

# YouTube / long video: TL;DR + 論點 + 時間點 + 值不值得看
ytsum() {
    summarize "$@" --prompt-file "$SUMMARIZE_PROMPT_DIR/youtube-zhtw.md"
}

# 30-second triage of any source: read it or skip it
sumq() {
    summarize "$@" --prompt-file "$SUMMARIZE_PROMPT_DIR/quickscan-zhtw.md" --length short
}

# Full-length summary, upstream's built-in structure
suml() {
    summarize "$@" --length long
}

# Machine-readable envelope, for piping into jq / an agent
sumj() {
    summarize "$@" --json
}
