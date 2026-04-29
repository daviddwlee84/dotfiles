# ffmpeg — 影音瑞士刀

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[FFmpeg](https://ffmpeg.org/) 是通用的影音 (audio/video) 工具鏈，幾乎所有上層工具（vhs、OBS、剪輯軟體、ASR pipeline）底層都在叫它。在這個 repo 透過 `installMediaTools=true` 一起裝進來，搭配 [ImageMagick](imagemagick.md)、[ExifTool](exiftool.md)、[libvips](libvips.md)。

- **安裝**：
  - macOS — Homebrew (`brew install ffmpeg`)，由 `dot_ansible/roles/media_tools/tasks/main.yml` 在 `installMediaTools=true` 時管理。
  - Linux — apt (`sudo apt install ffmpeg`)，同 role / 同 flag。`noRoot=true` 時自動跳過（apt 區塊掛 `tags: [sudo]`）。
- **驗證**：`ffmpeg -version | head -1` 與 `ffprobe -version | head -1`。
- **目前在這個 repo 的狀態**：透過 `installMediaTools=true` opt-in。三個 zsh helper（`compress-video`、`extract-audio`、`to-wav16k`）放在 [`dot_config/zsh/tools/29_media.zsh`](../../dot_config/zsh/tools/29_media.zsh) — 詳 [docs/zsh/aliases.md → Media / AV](../zsh/aliases.md#media--av)。同時也順便補上 [`vhs`](vhs.md) 錄製時必須的 runtime 依賴。

---

## 常見格式轉換

```bash
# 容器轉換 (.mov / .mkv / .webm → .mp4)
ffmpeg -i input.mov output.mp4

# 用 x264 + AAC 重新編碼
ffmpeg -i input.mov -c:v libx264 -c:a aac output.mp4
```

`-c copy` 會完全跳過重新編碼（codec 已相容時），快數量級；前提是來源 stream 對目標容器有效。

---

## 壓縮 — CRF 對照表

```bash
# 用 x264 把 MP4 壓小（preset slow 拿 CPU 換體積）。
ffmpeg -i input.mp4 -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 128k output.mp4
```

| `-crf` | 用途 |
|---|---|
| 18 | 視覺無損（封存母帶） |
| 23 | 預設 — 畫質好、體積合理 |
| 28 | 畫質尚可，約 CRF 23 的一半大小（`compress-video` zsh helper 用這個） |
| 32 | 激進 — 看得到 artifact 但檔案非常小 |

`-preset` 旋鈕（`ultrafast` → `placebo`）在同一 CRF 下用編碼時間換壓縮效率。

---

## 音訊

```bash
# 去掉影像、保留音訊不重新編碼（最快）
ffmpeg -i input.mp4 -vn -c:a copy output.m4a

# 重新編碼成乾淨的格式
ffmpeg -i input.wav output.mp3
ffmpeg -i input.flac output.m4a

# Whisper / faster-whisper / wav2vec 要 16 kHz 單聲道 WAV
ffmpeg -i input.m4a -ar 16000 -ac 1 output_16k.wav
```

最後兩個 pattern 由 [`extract-audio`](../zsh/aliases.md#media--av) 與 [`to-wav16k`](../zsh/aliases.md#media--av) 包好。

---

## 裁剪 / 截段

```bash
# 快速裁剪 (stream-copy) — 對齊 keyframe，可能多取一點點秒數
ffmpeg -ss 00:00:30 -i input.mp4 -t 10 -c copy clip.mp4

# 精確到 frame（會重新編碼）
ffmpeg -ss 00:00:30 -i input.mp4 -t 10 clip.mp4
```

`-ss` 放在 `-i` *前面* → input-side seek，快；放在 `-i` *後面* → output-side seek，慢但精準。

---

## 合併 (concat)

```bash
# files.txt:
#   file 'part1.mp4'
#   file 'part2.mp4'
ffmpeg -f concat -safe 0 -i files.txt -c copy output.mp4
```

所有輸入必須 codec + 解析度 + framerate 都一致；不一致就先重新編碼，或用 `-filter_complex concat=n=N:v=1:a=1`。

---

## Frame ↔ 影片

```bash
# 每 N 秒抓一張 PNG
ffmpeg -i input.mp4 -vf fps=1 frame_%04d.png

# 抓特定時間點的單張 frame
ffmpeg -ss 00:01:23 -i input.mp4 -frames:v 1 screenshot.png

# 圖片序列 → 影片（matplotlib 匯出、ML 訓練視覺化常用）
ffmpeg -framerate 30 -i frame_%04d.png -c:v libx264 -pix_fmt yuv420p output.mp4
```

`-pix_fmt yuv420p` 是瀏覽器 / Slack / iOS Quick Look 都吃的安全像素格式 — 不加它，x264 可能挑某些 player 拒播的 4:4:4 變體。

---

## GIF（以及為什麼通常 MP4 比較好）

```bash
# 簡易 GIF
ffmpeg -i input.mp4 -vf "fps=12,scale=640:-1" output.gif

# 高品質 GIF（palettegen → paletteuse 兩步驟）
ffmpeg -i input.mp4 -vf "fps=12,scale=640:-1,palettegen" /tmp/palette.png
ffmpeg -i input.mp4 -i /tmp/palette.png -lavfi "fps=12,scale=640:-1 [v]; [v][1:v] paletteuse" output.gif
```

同等視覺品質下，GIF 通常比 MP4/WebM 大 5–20 倍。除非目的地一定要 GIF（少數聊天平台還只吃 GIF），不然優先 MP4。

---

## 檢查資訊

```bash
ffprobe input.mp4
ffprobe -v error -show_format -show_streams input.mp4         # 結構化
ffprobe -v error -show_streams -of json input.mp4 | jq        # JSON pipeline
```

`ffprobe` 跟 ffmpeg 同一個 package — 不用另外裝。

---

## 字幕

```bash
# Soft（封裝）— 把 .srt 變成軌道，player 可以開關
ffmpeg -i input.mp4 -i subtitle.srt -c copy output.mkv

# Hard（燒錄）— 把字燒進像素，無法關掉
ffmpeg -i input.mp4 -vf subtitles=subtitle.srt output.mp4
```

Soft 字幕體積小、可編輯；hard 字幕在會剝掉字幕軌道的平台上仍會留下來。

---

## See also

- [VHS](vhs.md) — 終端機錄影；錄 GIF / MP4 必須 ffmpeg 在 runtime
- [ImageMagick](imagemagick.md) — 兄弟工具，處理**靜態圖**（單張影像變換）
- [ExifTool](exiftool.md) — 把這裡產出的影片去掉 metadata
- [libvips](libvips.md) — 批次圖片處理量超過 ImageMagick 能負荷時
- [docs/zsh/aliases.md → Media / AV](../zsh/aliases.md#media--av) — 隨包提供的三個 helper function
- 上游 cheatsheet：<https://trac.ffmpeg.org/wiki>
