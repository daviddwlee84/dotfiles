# summarize（YouTube / 網頁 / PDF → LLM 摘要）

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

選用角色 (`installSummarize`)。[`steipete/summarize`](https://github.com/steipete/summarize)
把一個 URL 或檔案變成摘要：YouTube 影片、podcast、網頁、PDF、本地音訊與影片。它自己負責
內容擷取管線 (ingestion pipeline)（官方字幕 → transcript API → `yt-dlp` 音訊 → Whisper），
再把文字交給你指定的模型。

有兩件事讓它比瀏覽器工作流更適合放進 dotfiles：它可以直接沿用**已登入的 coding CLI**
當後端 (`--cli claude`、`--cli codex`、`--cli gemini`、`--cli pi`)，不需要額外的 API key
或帳單來源；而且輸出語言是一個 config 鍵，所以摘要固定回繁體中文，不必動 OS 或瀏覽器語系。
其他考慮過的方案——Gemini in Chrome Skills、Chrome 擴充功能、Tampermonkey userscript、
Gemini API 的 YouTube URL input——比較表在 superproject 的 `docs/summarization-tooling.md`。

## 相關筆記

- [本地 LLM 工具](llm.md)：`installLlmTools` 角色，若你想要本地後端。
- [Copilot agent gateway](copilot-claude-proxy.md)：用 GitHub Copilot 訂閱撐起這些 coding CLI。
- [網頁讀取器](web-reader.md)：只要純文字而不要摘要時使用。

## 安裝路徑

| 平台 | 方式 | 說明 |
|---|---|---|
| macOS | `brew install summarize`（homebrew-core） | Homebrew 會一併拉 `ffmpeg`、`node`、`tesseract`、`yt-dlp` 這些 formula 相依 |
| Linux | `mise exec -- npm install -g @steipete/summarize` | 沒有 formula。需要 **Node 24+**，由 mise 的 `node@lts` 提供。CentOS/RHEL 7 baseline (`oldEL`) 會跳過 |
| Windows | `npm i -g @steipete/summarize` 加上 scoop 的 `ffmpeg` / `yt-dlp` / `tesseract` | 見 `dotfiles-windows` 的 [summarize 頁面](https://github.com/daviddwlee84/dotfiles-windows/blob/main/docs/summarize.zh-TW.md) |

ansible 角色是 `dot_ansible/roles/summarize/`，tag 為 `summarize`。

## 設定

`~/.summarize/config.json` 是以 chezmoi 的 **`modify_` overlay** 管理
（[`dot_summarize/modify_config.json`](../../dot_summarize/modify_config.json)），而不是
一般的受管檔案。原因有兩個：

- **這個路徑不是 XDG，而且沒辦法是。** summarize 把 `~/.summarize/config.json` 寫死了——
  沒有 XDG 查找，也沒有 `SUMMARIZE_CONFIG` 覆寫。這是本 repo「優先使用 XDG」規則的明文例外。
- **summarize 自己也會寫這個檔。** `summarize refresh-free` 會把 OpenRouter 免費模型
  presets 寫回這個檔，`--set-default` 則會持久化模型選擇。一般受管檔案會在每次
  `chezmoi apply` 覆蓋掉這兩者；overlay 改為合併 (merge)，我們的鍵維持權威，工具寫入的內容
  也保留下來。

受管的 overlay 刻意寫得很小：

```json
{
  "output": {
    "language": "zh-TW",
    "length": "medium"
  }
}
```

頂層的 `prompt` 鍵**刻意不設**。它會*取代* summarize 內建的摘要指令——連同結構與格式指引——
而且是對**所有**來源類型生效，不只影片。分來源的 prompt 改走 `--prompt-file`。

上游的優先順序是：CLI flag → `~/.summarize/config.json` → 內建預設。所以
`summarize --language en <url>` 仍然可以單次覆蓋受管的預設語言。

## Prompt presets

放在 `~/.config/summarize/prompts/` 的一般受管檔案（summarize 不會寫這裡，所以維持 XDG）：

| 檔案 | 結構 |
|---|---|
| `youtube-zhtw.md` | TL;DR → 主要論點 → 值得注意的細節 → 重要時間點 → 值不值得完整觀看 |
| `quickscan-zhtw.md` | 一句話結論 → 三個重點 → 值得 / 略讀即可 / 跳過 |

兩者都把語言固定為繁體中文（台灣用語），並保留技術名詞、產品名與 API/CLI 識別字的英文原文。

## 指令

包裝函式放在 [`dot_config/shell/32_summarize.sh`](../../dot_config/shell/32_summarize.sh)。

```bash
# 直接呼叫——因為受管 config，已經是繁體中文
summarize 'https://youtu.be/xxxx'

# 影片：TL;DR + 論點 + 時間點 + 值不值得看
ytsum 'https://youtu.be/xxxx'

# 任何內容的 30 秒分流：要讀還是跳過
sumq 'https://example.com/long-post'

# 完整長度摘要，使用上游內建結構
suml 'https://youtu.be/xxxx'

# JSON envelope，給 jq 或 agent 用
sumj 'https://youtu.be/xxxx' | jq -r '.summary'

# 沿用已登入的 coding CLI，而非 API key
summarize 'https://youtu.be/xxxx' --cli claude

# 單次覆蓋受管語言
summarize 'https://youtu.be/xxxx' --language en

# 這台機器實際有哪些 provider？
summarize status --verbose
```

## YouTube 管線如何降級 (degrade)

```text
官方字幕軌
        │ 取不到
youtubei / Apify transcript
        │ 取不到
yt-dlp 音訊 → Whisper
        │
        └─→ 你選的模型
```

`--slides` 會加上場景變化的關鍵影格 (keyframes)，`--slides-ocr` 則對它們做 OCR——
`tesseract` 這個相依就是為此而來。`--extract` 完全跳過模型，只給你清理過的原始文字。

## 升級

沒有工具專屬的路徑：macOS formula 由 `just upgrade-brew` 處理，Linux/Windows 的全域套件
由 `just upgrade-npm` 處理。見[升級](../this_repo/upgrades.md)。
