# libvips — 高吞吐圖片處理

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[libvips](https://www.libvips.org/) 是為**大圖**和**多圖**調校的 streaming（串流式）影像處理 library：低記憶體、partial read、平行 pipeline。ImageMagick 把每張圖整張 load 進 RAM；libvips 只串它真正需要的 pixel 通過操作。1k 張以上、或單張幾百 MB 以上時，這才是對的工具。透過 `installMediaTools=true` 一起裝，搭配 [ffmpeg](ffmpeg.md)、[ImageMagick](imagemagick.md)、[ExifTool](exiftool.md)。

- **安裝**：
  - macOS — Homebrew (`brew install vips`)，由 `dot_ansible/roles/media_tools/tasks/main.yml` 在 `installMediaTools=true` 時管理。
  - Linux — apt (`sudo apt install libvips-tools`)，同 role / 同 flag。`-tools` 套件帶 CLI（`vips`、`vipsthumbnail`、`vipsedit`、`vipsheader`）；單純的 `libvips42` 是純 library。
- **驗證**：`vips --version` 與 `vipsthumbnail --version`。
- **目前在這個 repo 的狀態**：透過 `installMediaTools=true` opt-in。沒有自動化在叫它 — 留著給 ImageMagick 撐不住的時候用。

---

## 什麼時候選 libvips、什麼時候選 ImageMagick？

| 情境 | 選 |
|---|---|
| 單張、複雜合成 / 加註 | [ImageMagick](imagemagick.md) |
| 一次性 resize / crop | 都行；ImageMagick 比較熟 |
| 1k 張以上批次 | **libvips**（通常快 5–10×、記憶體 1/10） |
| 單張 > 500 MB / gigapixel 掃描檔 | **libvips**（ImageMagick 可能 OOM） |
| Server-side thumbnail pipeline | **libvips**（`vipsthumbnail` 就是為這設計） |
| 互動式臨時調整 | [ImageMagick](imagemagick.md)（一行更順手） |

兩個是互補的，預設都裝著。

---

## `vipsthumbnail` — 殺手級用途

從超大圖產 thumbnail，永不把整張 pixel buffer load 進來：

```bash
# 單張 — 長邊上限 1280px
vipsthumbnail input.jpg --size 1280 -o output.jpg

# 鎖寬（高自動）
vipsthumbnail input.jpg --size '1280x'

# 鎖高（寬自動）
vipsthumbnail input.jpg --size 'x720'

# Output template — 寫到原檔旁邊 <name>_tn.jpg
vipsthumbnail *.jpg --size 320 -o '%s_tn.jpg'

# 自訂輸出目錄
vipsthumbnail *.jpg --size 320 -o 'thumbs/%s.jpg[Q=85]'
```

`%s` 在 output template 展開為輸入檔的 basename（不含副檔名）。`[Q=85]` 後綴設 JPEG 品質。

對 raw 相機檔 / TIFF / WebP / HEIC — vipsthumbnail 會自動挑對的 loader，只 decode 目標尺寸需要的區域。

---

## `vips` — 操作執行器

```bash
# Resize（保持比例）
vips resize input.jpg output.jpg 0.5     # 一半大小

# Crop — left, top, width, height
vips crop input.jpg output.jpg 100 50 800 600

# 旋轉
vips rot input.jpg output.jpg d90        # 順時針 90°；d180 / d270

# 翻轉
vips flip input.jpg output.jpg horizontal

# 存檔時 strip ICC + metadata（檔案更小）
vips copy input.jpg output.jpg[strip,Q=85]
```

Saver 選項（`Q=...`、`strip`、`interlace`、`optimize_coding`、`subsample_mode=...`）放在輸出路徑後的 `[brackets]`。Loader 同樣語法（多頁 TIFF：`input.tif[page=2]`）。

---

## 各格式 saver

```bash
# JPEG 自訂品質
vips copy input.png output.jpg[Q=80,optimize_coding,strip]

# WebP（更小、現代）
vips copy input.png output.webp[Q=80,strip,effort=4]

# AVIF（最小、編碼最慢）
vips copy input.png output.avif[Q=50,effort=6]

# Tiled / pyramid TIFF（OpenSeadragon 等 viewer 可以縮放）
vips copy input.jpg output.tif[tile,pyramid,compression=jpeg,Q=85]
```

`vips --vips-help-loaders` 與 `--vips-help-savers` 列完整選項。

---

## 檢查資訊

```bash
vipsheader input.jpg                     # 一行 header
vipsheader -a input.jpg                  # 全部 tag
vipsheader -f width input.jpg            # 單一欄位
vipsheader -f vips-loader input.jpg      # 用了哪個 loader
```

---

## Pipeline

libvips 的 streaming model 讓 pipeline 記憶體有界：

```bash
# 先 resize 再轉 jpeg → 檔案更小，永不 load 整張
vips resize input.tif output.jpg[Q=85] 0.25

# Sequential mode 給超大檔用 — 從上到下讀，不能往回 seek
vipsthumbnail huge_scan.tif --size 2000 -o thumb.jpg --intent perceptual
```

Python（與其他 binding）用法見 <https://www.libvips.org/API/current/python.html>。CLI 已經涵蓋大部分批次需求。

---

## 注意事項

- **沒有 `convert input output`** — 每個操作都有動詞（`resize`、`crop`、`rot` …）。`vips list classes` 列全部。
- **Saver 選項放在中括號裡** — `output.jpg Q=85` 不會生效；`output.jpg[Q=85]` 才行。容易漏。
- **色彩 profile** — 預設 vips 會保留嵌入的 ICC profile。下游不處理就加 `[strip]`，或先 `vips icc_transform` 轉一下。
- **Sequential mode lock-in** — `vipsthumbnail --intent perceptual` 之類會切到 streaming mode。center crop 等隨機存取在那個 mode 不能用；改用 `vips`。

---

## See also

- [ImageMagick](imagemagick.md) — 日常對應工具；只在規模需要時才挑 libvips
- [ExifTool](exiftool.md) — libvips 的 `[strip]` 是全有全無；要外科手術式編 metadata 用 exiftool
- [ffmpeg](ffmpeg.md) — 動態影像 / 影片 frame
- 上游 API 參考：<https://www.libvips.org/API/current/>
- 效能筆記與 benchmark：<https://github.com/libvips/libvips/wiki/Speed-and-memory-use>
