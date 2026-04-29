# ImageMagick — 圖片瑞士刀

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[ImageMagick](https://imagemagick.org/) 是單張影像與小批次處理（轉檔、resize、crop、合成、加註、濾鏡）的事實標準 CLI。透過 `installMediaTools=true` 一起裝，搭配 [ffmpeg](ffmpeg.md)、[ExifTool](exiftool.md)、[libvips](libvips.md)。

- **安裝**：
  - macOS — Homebrew (`brew install imagemagick`)，是 v7，提供統一的 `magick` 入口。由 `dot_ansible/roles/media_tools/tasks/main.yml` 在 `installMediaTools=true` 時管理。
  - Linux — apt (`sudo apt install imagemagick`)。Ubuntu 24.04 仍預設裝 **v6**，沒有統一的 `magick`，要用 legacy 命令（`convert`、`identify`、`mogrify`、`composite` …）。同 role / 同 flag。
- **驗證**：`magick --version`（v7）或 `convert --version`（v6）。
- **目前在這個 repo 的狀態**：透過 `installMediaTools=true` opt-in。沒有自動化在叫它，純為臨時圖片處理而裝。

---

## v6 vs v7 — 用哪個指令？

ImageMagick 7 把所有 legacy 執行檔統一在 `magick` 後面：

```bash
# v7 (macOS Homebrew)
magick input.png -resize 1280x output.png

# v6 (Ubuntu 24.04 apt)
convert input.png -resize 1280x output.png
```

`magick` 本身也接 `magick convert ...` / `magick identify ...` 等向後相容寫法。要寫可攜的 script，優先用 `magick`，找不到再 fallback 到 `convert`：

```bash
IM=$(command -v magick || command -v convert)
"$IM" input.png -resize 1280x output.png
```

下面範例都用 `magick`；在 Ubuntu 24.04 上心裡換成 `convert` 即可。

---

## 常見變換

```bash
# 看資訊
magick identify input.png                    # 一行摘要
magick identify -verbose input.png | head -40

# Resize（保持比例）
magick input.png -resize 1280x output.png    # 寬上限 1280
magick input.png -resize 1280x720 output.png # 框進 1280×720

# Crop
magick input.png -crop 800x600+100+50 output.png   # WIDTHxHEIGHT+X+Y

# 品質 / 格式
magick input.jpg -quality 85 output.jpg
magick input.png -background white -alpha remove output.jpg   # PNG → JPG，alpha 用白色填
```

`-resize 1280x` 保持比例；`-resize 1280x720!`（加 `!`）強制尺寸，會變形。

---

## 批次 resize / 轉檔

```bash
mkdir -p resized
for f in *.jpg; do
  magick "$f" -resize 1280x "resized/$f"
done
```

幾千張以上請看 [libvips](libvips.md) — `vipsthumbnail` 通常快 5–10×、記憶體用量是 ImageMagick 的 1/10。

`mogrify`（v6）/ `magick mogrify`（v7）就地修改，快但是破壞性的：

```bash
magick mogrify -resize 1280x -path resized/ *.jpg     # 寫到 resized/，原檔不動
magick mogrify -resize 1280x *.jpg                    # 直接覆寫原檔
```

---

## 合成

```bash
# 把 logo 疊到右下角，留 20px 間距
magick input.png logo.png \
  -gravity southeast -geometry +20+20 \
  -composite output.png

# 加實心邊框
magick input.png -bordercolor white -border 20 output.png

# 圓角（alpha mask 小技巧）
magick input.png \
  \( +clone -alpha extract \
     -draw 'fill black polygon 0,0 0,15 15,0 fill white circle 15,15 15,0' \
     \( +clone -flip \) -compose Multiply -composite \
     \( +clone -flop \) -compose Multiply -composite \
  \) -alpha off -compose CopyOpacity -composite rounded.png
```

合成是 ImageMagick 勝過 ffmpeg 的場景 — 語法雖然密但就是為單張圖片設計的。

---

## 加註文字

```bash
# 在圖片下方加 caption
magick input.png \
  -gravity south -background "#00000088" -fill white \
  -splice 0x40 -annotate +0+10 'Caption text' \
  output.png
```

要重複套用一致樣式，存成設定檔或包成 shell function。

---

## 格式轉換捷徑

```bash
magick input.heic output.jpg     # HEIC → JPG（要 libheif 支援；查 `magick -list format`）
magick input.svg -density 300 output.png   # SVG → 高 DPI PNG
magick *.jpg output.pdf          # JPG → 多頁 PDF
magick input.pdf[0] cover.png    # PDF 第一頁 → PNG（要 ghostscript）
```

PDF 支援取決於 Ghostscript。macOS Homebrew 會自動拉成依賴；Ubuntu 要另裝（`sudo apt install ghostscript`）。

---

## 注意事項

- **PDF / PostScript policy** — 較新的 Debian / Ubuntu 預設裝的 `/etc/ImageMagick-6/policy.xml` 會擋 PDF 讀取（CVE-2018-16509）。如果 `magick input.pdf cover.png` 噴 "not authorized"，改 policy 或先用 `pdftoppm` 過一手。
- **記憶體上限** — 同一個 policy.xml 也卡了記憶體 / 面積 / 磁碟。大批次請改 libvips。
- **Determinism** — 用 flag 鎖定 font、density、colorspace，兩次跑同一輸入會 byte-identical。對視覺 regression test 有用。

---

## See also

- [libvips](libvips.md) — ImageMagick 在記憶體或速度上頂不住時用（>1k 張）
- [ExifTool](exiftool.md) — ImageMagick 轉檔時可能洗掉 EXIF；exiftool 可以幫你保留 / 移除你選定的 metadata
- [ffmpeg](ffmpeg.md) — 動態影像（frame extraction、GIF、螢幕錄影）
- [Freeze](freeze.md) — 程式碼 → 圖片用這個（不要用 `magick`）
- 上游用法：<https://imagemagick.org/script/command-line-options.php>
