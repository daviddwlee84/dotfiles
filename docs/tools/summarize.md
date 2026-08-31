# summarize (YouTube / web / PDF → LLM summary)

Optional role (`installSummarize`). [`steipete/summarize`](https://github.com/steipete/summarize)
turns a URL or a file into a summary: YouTube videos, podcasts, webpages, PDFs, local
audio and video. It owns the ingestion pipeline (captions → transcript APIs → `yt-dlp`
audio → Whisper) and then hands the text to whichever model you point it at.

Two things make it a better fit here than a browser workflow: it can reuse an
**already-authenticated coding CLI** as its backend (`--cli claude`, `--cli codex`,
`--cli gemini`, `--cli pi`), so no extra API key or billing account is involved; and the
output language is a config key, so summaries come back in 繁體中文 without touching the
OS or browser locale. The alternatives that were considered — Gemini in Chrome Skills,
the Chrome extensions, a Tampermonkey userscript, the Gemini API's YouTube-URL input —
are compared in the superproject's `docs/summarization-tooling.md`.

## Related Notes

- [Local LLM Tools](llm.md): the `installLlmTools` role, if you want a local backend.
- [Copilot agent gateway](copilot-claude-proxy.md): backing the coding CLIs with a
  GitHub Copilot subscription.
- [Web reader](web-reader.md): the plain page-to-Markdown readers, when you want the
  text rather than a summary.

## Install path

| Platform | How | Notes |
|---|---|---|
| macOS | `brew install summarize` (homebrew-core) | Homebrew pulls `ffmpeg`, `node`, `tesseract`, `yt-dlp` as formula dependencies |
| Linux | `mise exec -- npm install -g @steipete/summarize` | No formula exists. Needs **Node 24+**, which mise's `node@lts` provides. Skipped on the CentOS/RHEL 7 baseline (`oldEL`) |
| Windows | `npm i -g @steipete/summarize` + scoop `ffmpeg` / `yt-dlp` / `tesseract` | See `dotfiles-windows`' [summarize page](https://github.com/daviddwlee84/dotfiles-windows/blob/main/docs/summarize.md) |

The ansible role is `dot_ansible/roles/summarize/`, tag `summarize`.

## Configuration

`~/.summarize/config.json` is managed as a chezmoi **`modify_` overlay**
([`dot_summarize/modify_config.json`](../../dot_summarize/modify_config.json)), not as a
plain file. Two reasons:

- **The path is not XDG, and cannot be.** summarize hardcodes `~/.summarize/config.json`
  — there is no XDG lookup and no `SUMMARIZE_CONFIG` override. This is the documented
  exception to the repo's prefer-XDG rule.
- **summarize is a second writer.** `summarize refresh-free` rewrites the OpenRouter
  free-model presets into this file, and `--set-default` persists a model choice. A
  plain managed file would clobber both on every `chezmoi apply`; the overlay merges
  instead, so our keys stay authoritative and everything the tool wrote survives.

The managed overlay is deliberately small:

```json
{
  "output": {
    "language": "zh-TW",
    "length": "medium"
  }
}
```

The top-level `prompt` key is **deliberately absent**. It *replaces* summarize's
built-in summary instructions — structure and formatting guidance included — for every
source type, not just video. Per-source prompts go through `--prompt-file` instead.

Precedence upstream is: CLI flag → `~/.summarize/config.json` → built-in default. So
`summarize --language en <url>` still overrides the managed default per call.

## Prompt presets

Plain managed files under `~/.config/summarize/prompts/` (summarize never writes here,
so these stay XDG):

| File | Shape |
|---|---|
| `youtube-zhtw.md` | TL;DR → 主要論點 → 值得注意的細節 → 重要時間點 → 值不值得完整觀看 |
| `quickscan-zhtw.md` | 一句話結論 → 三個重點 → 值得 / 略讀即可 / 跳過 |

Both fix the language to 繁體中文（台灣用語） and keep technical terms, product names and
API/CLI identifiers in their original English.

## Commands

Wrappers live in [`dot_config/shell/32_summarize.sh`](../../dot_config/shell/32_summarize.sh).

```bash
# Plain call — already 繁體中文, thanks to the managed config
summarize 'https://youtu.be/xxxx'

# Video: TL;DR + 論點 + 時間點 + 值不值得看
ytsum 'https://youtu.be/xxxx'

# 30-second triage of anything: read it or skip it
sumq 'https://example.com/long-post'

# Full-length summary with upstream's built-in structure
suml 'https://youtu.be/xxxx'

# JSON envelope, for jq or an agent
sumj 'https://youtu.be/xxxx' | jq -r '.summary'

# Reuse an authenticated coding CLI instead of an API key
summarize 'https://youtu.be/xxxx' --cli claude

# Override the managed language for one call
summarize 'https://youtu.be/xxxx' --language en

# Which providers does this box actually have?
summarize status --verbose
```

## How the YouTube pipeline degrades

```text
official caption track
        │ unavailable
youtubei / Apify transcript
        │ unavailable
yt-dlp audio → Whisper
        │
        └─→ your chosen model
```

`--slides` adds scene-change keyframes and `--slides-ocr` OCRs them (that is what the
`tesseract` dependency is for). `--extract` skips the model entirely and just gives you
the cleaned source text.

## Upgrades

Nothing tool-specific: `just upgrade-brew` covers the macOS formula and
`just upgrade-npm` covers the Linux/Windows global. See [upgrades](../this_repo/upgrades.md).
