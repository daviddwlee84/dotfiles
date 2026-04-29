# ExifTool — 圖片 / 影片 metadata 讀寫工具

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[ExifTool](https://exiftool.org/) 是讀取、寫入、清除影像 / 影片 / 音訊中 metadata（EXIF、IPTC、XMP、GPS、MakerNotes …）的標準 CLI。透過 `installMediaTools=true` 一起裝，搭配 [ffmpeg](ffmpeg.md)、[ImageMagick](imagemagick.md)、[libvips](libvips.md)。

- **安裝**：
  - macOS — Homebrew (`brew install exiftool`)，由 `dot_ansible/roles/media_tools/tasks/main.yml` 在 `installMediaTools=true` 時管理。
  - Linux — apt (`sudo apt install libimage-exiftool-perl`)，同 role / 同 flag。套件名反映了 exiftool 是 Perl script + module 套件 — 不是打錯。
- **驗證**：`exiftool -ver`。
- **目前在這個 repo 的狀態**：透過 `installMediaTools=true` opt-in。沒有自動化在叫它。

---

## 讀取

```bash
# 人類可讀摘要
exiftool image.jpg

# 只看特定 tag
exiftool -DateTimeOriginal -GPSPosition -Make -Model image.jpg

# JSON 輸出（pipeline-friendly）
exiftool -json image.jpg | jq

# 遞迴掃描整個目錄
exiftool -r ~/Photos

# 特定類別
exiftool -GPS:all video.mov
```

---

## 移除 metadata（隱私）

從手機剛拍的照片會洩漏 GPS 座標、相機序號、擁有者姓名、app 指紋。在公開分享前：

```bash
# 全部清掉（會建立 image.jpg_original 備份）
exiftool -all= image.jpg

# 全部清掉、不留備份
exiftool -all= -overwrite_original image.jpg

# 只清隱私敏感的 tag，保留 EXIF 拍攝資訊
exiftool -GPS:all= -Make= -Model= -SerialNumber= image.jpg

# 遞迴清
exiftool -all= -overwrite_original -r ~/Photos
```

`_original` 備份是 exiftool 的安全網 — 沒加 `-overwrite_original` 你會看到 `IMG_1234.jpg` 跟 `IMG_1234.jpg_original` 並排。一次性處理很方便，批次會痛苦；按需求挑。

> **隱私提醒** — 跟 [Freeze](freeze.md) 的「不要截圖機密」是同一個警告：發布前先洗。公開頁會被爬蟲抓、被截圖、被存檔；今天上傳的東西永遠下載得到。

---

## 寫入 / 編輯

```bash
# 設一個 tag
exiftool -Artist="Da-Wei Lee" image.jpg

# 修正錯誤的拍攝時間（時區偏移）
exiftool -AllDates+="0:0:0 1:0:0" *.jpg     # 全部 +1 小時

# 用數字座標蓋章 GPS
exiftool -GPSLatitude=25.0330 -GPSLongitude=121.5654 -GPSLatitudeRef=N -GPSLongitudeRef=E image.jpg

# 從一個檔案把 metadata 複製到另一個
exiftool -TagsFromFile source.jpg target.jpg
exiftool -TagsFromFile source.jpg -all:all target.jpg     # 全部
```

Tag 名不分大小寫。`exiftool -listx 2>&1 | head -50` 看完整列表。

---

## 依 metadata 重新命名 / 整理

```bash
# 用 EXIF DateTimeOriginal 改名為 YYYYMMDD_HHMMSS.jpg
exiftool '-FileName<DateTimeOriginal' -d '%Y%m%d_%H%M%S.%%e' *.jpg

# 搬進 year/month 子目錄
exiftool '-Directory<DateTimeOriginal' -d '%Y/%m' -r ~/Photos

# 先 dry run — exiftool 會真的搬檔，不只是印出來
exiftool '-FileName<DateTimeOriginal' -d '%Y%m%d_%H%M%S.%%e' -if 'not $self{Directory_changed}' --testname *.jpg
```

`%%e` 是 exiftool 字面 `%e` — 原檔副檔名（小寫）。單 `%` 是 `strftime`。

---

## Pipeline

```bash
# 把沒有 GPS 的照片排到最上面 — triage 用
exiftool -p '$GPSPosition $FileName' -if '$GPSPosition eq ""' -r ~/Photos

# CSV 匯出進試算表
exiftool -csv -DateTimeOriginal -Make -Model -GPSPosition -r ~/Photos > photos.csv

# Diff 兩個檔案的 metadata
diff <(exiftool a.jpg) <(exiftool b.jpg)
```

---

## 注意事項

- **預設備份吃硬碟** — `_original` 累積得很快。確認操作沒問題後就 `-overwrite_original`，或事後用 `find . -name '*_original' -delete` 掃掉。
- **某些格式只支援部分 tag** — exiftool 會悄悄跳過容器不支援的寫入。要看到底寫進去什麼，加 `-v3`。
- **GPS 沒 ref 方向** — `-GPSLatitude=25.0330` 預設當北半球；南半球要 `-GPSLatitudeRef=S` 加正數（或用接受帶號的 `-XMP-exif:GPSLatitude` API）。容易踩雷。
- **Sidecar XMP** — raw 相機檔請寫到 `IMG_1234.xmp`，不要動原始 raw。`exiftool -o %d%f.xmp image.cr2` 會建 sidecar。

---

## See also

- [ImageMagick](imagemagick.md) — 在 `magick input.jpg output.jpg` 時會洗掉大部分 metadata；搭配 exiftool 的 `-TagsFromFile` 保留你要的
- [ffmpeg](ffmpeg.md) — 也讀容器 metadata（`ffprobe`）；要更細緻的編輯或處理靜態圖用 exiftool
- [Freeze](freeze.md) — 隱私警告對截圖也一樣適用
- 上游 tag 參考：<https://exiftool.org/TagNames/index.html>
