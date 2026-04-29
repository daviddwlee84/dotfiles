# 輸入法 (Input Methods)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

以 macOS 為主，記錄這個 dotfiles repo 目前使用與追蹤的繁體中文輸入法相關資訊，重點放在：

- McBopomofo
- Rime / Squirrel
- app 切換時的輸入法狀態
- `vim_mode`、`ascii_mode`、全域狀態 (global state) 等已知限制
- 哪些檔案適合備份，哪些不適合直接納入 chezmoi

本文內容以目前這台機器的實際狀態為基準整理，並補上 upstream 文件與 issue / PR 連結。

## 相關筆記 (Related Notes)

- [macOS 系統層級輸入來源切換](macos-system-switching.md)：不依賴 Rime / Squirrel 內建切換時，Apple 原生、Input Source Pro、Hammerspoon、Keyboard Maestro / BetterTouchTool、`macism`、`im-select`、Karabiner 等方案的比較

## 本機已驗證的路徑與狀態

驗證日期：`2026-03-31`

### Squirrel / Rime

本機已確認存在：

- `~/Library/Rime/squirrel.custom.yaml`
- `~/Library/Rime/user.yaml`
- `~/Library/Rime/installation.yaml`
- `~/Library/Rime/build/`
- `~/Library/Rime/sync/<installation_id>/`

本機目前狀態：

- Squirrel app 存在於 `"/Library/Input Methods/Squirrel.app"`
- Squirrel `CFBundleVersion` = `1.1.2`
- `~/Library/Rime/installation.yaml` 顯示 `distribution_version: 1.1.2`
- `~/Library/Rime/installation.yaml` 顯示 `rime_version: 1.16.0`
- `~/Library/Rime/sync/43cea773-1593-4ccc-a2f3-a852974cbec4/` 已存在，表示目前有啟用 Rime 同步資料夾

### McBopomofo

本機已確認存在：

- `~/Library/Application Support/McBopomofo/data.txt`
- `~/Library/Application Support/McBopomofo/data-plain-bpmf.txt`
- `~/Library/Application Support/McBopomofo/exclude-phrases.txt`
- `~/Library/Application Support/McBopomofo/exclude-phrases-plain-bpmf.txt`
- `~/Library/Application Support/McBopomofo/phrases-replacement.txt`
- `~/Library/Preferences/org.openvanilla.inputmethod.McBopomofo.plist`
- `~/Library/Input Methods/McBopomofo.app`

補充：

- 這台機器的 McBopomofo 是 user-scope app，位於 `~/Library/Input Methods/`
- repo 內目前的 ansible role 只檢查 `/Library/Input Methods/`；這是獨立的 follow-up，本文只記錄，不在這一輪修

## Rime / Squirrel 客製化

Rime 的客製化原則是：不要直接改內建 schema 或發行版 yaml，而是使用 `*.custom.yaml` 搭配 `patch:` 覆寫。這也是官方 wiki 在 [CustomizationGuide](https://github.com/rime/home/wiki/CustomizationGuide) 中反覆使用的做法。

macOS 的 Squirrel 對應檔通常是：

- `squirrel.custom.yaml`：Squirrel 前端相關設定，例如 `style`、`app_options`
- `<schema>.custom.yaml`：特定方案的覆寫，例如 `bopomofo.custom.yaml`
- `default.custom.yaml`：全域預設覆寫

一個精簡、有代表性的 `squirrel.custom.yaml` 範例：

```yaml
patch:
  app_options:
    com.microsoft.VSCode:
      ascii_mode: true
    com.apple.Terminal:
      ascii_mode: true
      no_inline: true
      vim_mode: true
      inline_preedit: false
```

### `app_options`、`ascii_mode`、`no_inline`、`vim_mode`

- `app_options`：針對特定 app 的 bundle identifier 設定行為
- `ascii_mode: true`：該 app 預設以西文模式起始
- `no_inline: true`：停用行內組字 (inline composing)，通常在終端或編輯器更穩定
- `vim_mode: true`：目標是讓 Vim 類場景在離開 insert mode 時回到西文狀態，但在 macOS Terminal 類 app 上並不可靠
- `inline_preedit: false`：常和 `no_inline` 一起使用，降低終端內組字與 `Esc` 互動的干擾

這些選項在 Squirrel 內建的 `squirrel.yaml` 就能看到預設範例，例如 `com.apple.Terminal`、`com.googlecode.iterm2`、`org.vim.MacVim`。

### 修改後如何生效

修改 `*.custom.yaml` 後，需要在 macOS 輸入法選單對鼠鬚管執行「重新佈署」(redeploy)。

根據 Rime wiki 的說法，鼠鬚管是在系統語言文字選單中選擇「重新佈署」；對設定的修改會在重新佈署後生效。

### 查 app identifier

`app_options` 需要 bundle identifier。最直接的查法：

```bash
osascript -e 'id of app "Visual Studio Code"'
osascript -e 'id of app "Terminal"'
```

本機已驗證：

- `Visual Studio Code` -> `com.microsoft.VSCode`
- `Terminal` -> `com.apple.Terminal`

如果是第三方 app，也可以先用 Finder 確認正式 app 名稱，再用同樣方式查。

## 目前最在意的問題

### App 切換時輸入法狀態不可靠

目前痛點非常明確：在不同視窗或 app 之間切換後，很難確定當前到底是中文還是英文狀態。

典型情境：

1. 在某個視窗切成英文
2. `Command+Tab` 到下一個視窗
3. 狀態變成中文
4. 再切回原本視窗，狀態仍然可能是中文

這不是單靠 `app_options` 就能完全解決的問題。`app_options` 比較像是「進入 app 時的偏好」，不是可靠的全域狀態同步機制。

### `vim_mode` 在 Terminal 類 app 上不可靠

截至 `2026-03-31`，[`rime/squirrel#1023`](https://github.com/rime/squirrel/issues/1023) 仍是 open，問題標題就是「Terminal Vim_mode 無作用」，描述的現象與目前痛點一致：

- VS Code 可部分工作
- Terminal 內按 `Esc` 後不一定能回到西文
- 導致 `h j k l` 等按鍵仍進入中文輸入狀態

因此目前比較保守的結論是：

- `vim_mode` 可以保留，因為在部分 app 或部分情境仍有幫助
- 但不要把它當成 Terminal / iTerm / TUI 場景的可靠保證

## 已知限制與 upstream 狀態

以下狀態都以 `2026-03-31` 查閱 GitHub 為準。

### 1. 全域中英狀態目前仍無可靠的官方解法

- [`rime/home#202`](https://github.com/rime/home/issues/202) 仍為 open。這個 issue 自 `2017-12-24` 起就在問「全域統一中英切換」。
- [`rime/squirrel#145`](https://github.com/rime/squirrel/issues/145) 仍為 open。主題就是「是否有可能將中英文輸入狀態作全域管理？」
- [`rime/librime#294`](https://github.com/rime/librime/issues/294) 仍為 open。它把問題提升到 librime 層，直接討論是否要讓所有 client app 共用 global input session / state。

綜合這幾個 issue，可以合理推論目前的限制不只是單一 app 設定問題，而是牽涉到 Squirrel 與 librime 的狀態模型 (state model)。

### 2. `global_ascii` 目前不能當成已正式可用的功能

- [`rime/squirrel#201`](https://github.com/rime/squirrel/pull/201) 是一個想把 `ascii_mode` 做成跨 app 全域狀態的舊 PR；截至 `2026-03-31` 已 closed，未合併
- [`rime/squirrel#1054`](https://github.com/rime/squirrel/pull/1054) 嘗試用 `global_ascii` 配置項處理這件事；截至 `2026-03-31` 也已 closed，且沒有 merged 標記

本機安裝的 Squirrel `1.1.2` 內容裡也找不到 `global_ascii` 關鍵字，因此目前不應把 `global_ascii` 寫成已可依賴的方案。

### 3. 實務上的結論

目前比較務實的策略是：

- 用 `app_options` 管理每個 app 的「偏好初始狀態」
- 在終端與編輯器場景搭配 `no_inline: true`
- 視需要保留 `vim_mode: true`，但承認它在 Terminal 類 app 上不可靠
- 如果重點是「可見性」(visibility)，用額外工具顯示當前輸入法狀態，而不是期待 Rime 已經解決全域同步

## 狀態可見性工具

[ShowyEdge](https://github.com/pqrs-org/ShowyEdge/) 的定位很清楚：它是 macOS 的「current input source 可視化指示器」(visualization indicator)。

這類工具的價值在於：

- 讓你一眼看出現在是 ABC、注音、拼音或其他輸入來源
- 降低 app / 視窗切換之後的狀態不確定感

但它不是 Rime / Squirrel / librime 的全域狀態修復器。比較準確的期待應該是：

- 它能改善觀測 (observation)
- 不能保證改善切換行為本身

## 備份策略

這一輪的預設策略是：只備份「手寫設定」與「手動維護內容」，不把所有執行時產物 (runtime artifacts) 都當成 source of truth。

### Rime：建議備份

優先備份：

- `~/Library/Rime/*.custom.yaml`
- 目前最重要的是 `~/Library/Rime/squirrel.custom.yaml`

如果之後開始客製 schema，也一併把這些視為手寫設定：

- `~/Library/Rime/default.custom.yaml`
- `~/Library/Rime/bopomofo.custom.yaml`
- 其他 `<schema>.custom.yaml`

### Rime：先不要直接納入 chezmoi 的內容

以下檔案不建議直接當成 repo 內主要真相來源：

- `~/Library/Rime/build/`
- `~/Library/Rime/installation.yaml`
- `~/Library/Rime/user.yaml`
- `~/Library/Rime/*.userdb/`

原因：

- `build/` 是重新佈署後的編譯產物
- `installation.yaml` 偏向機器與安裝資訊
- `user.yaml` 偏向執行狀態與最近使用的方案
- `*.userdb/` 是 live user dictionary / frequency data，變動頻繁，直接納管很吵

### Rime：`sync/` 的定位

`~/Library/Rime/sync/<installation_id>/` 應該視為同步或匯出產物，不是主要 source of truth。

它有兩個用途：

- 跨機同步時，可作為 Rime 自己輸出的可攜資料 (portable data)
- 在需要救援或搬機時，可作為 userdb 快照與 custom 檔副本

但 repo 策略上，仍建議以手寫的 `*.custom.yaml` 當主要真相來源，而不是以 `sync/` 內容反推設定。

### McBopomofo：建議備份

McBopomofo 官方手冊明確提到：

- 使用者詞彙分頁管理的是純文字檔
- 這些文字檔位置可以自行決定
- 甚至可以放到 Google Drive / OneDrive / iCloud Drive 方便備份

以本機目前狀態，建議優先備份：

- `~/Library/Application Support/McBopomofo/data.txt`
- `~/Library/Application Support/McBopomofo/data-plain-bpmf.txt`
- `~/Library/Application Support/McBopomofo/exclude-phrases.txt`
- `~/Library/Application Support/McBopomofo/exclude-phrases-plain-bpmf.txt`
- `~/Library/Application Support/McBopomofo/phrases-replacement.txt`

### McBopomofo：可選備份

可選：

- `~/Library/Preferences/org.openvanilla.inputmethod.McBopomofo.plist`

理由：

- 這裡主要是偏好設定與行為選項
- 對於詞庫與自訂詞本身不是唯一來源
- 如果目標是低噪音、可審查、適合版本控制 (version control)，文字詞庫的優先級更高

## 之後若要正式納入 chezmoi

這一輪先不把輸入法資料正式納管進 repo，但如果下一輪要做，建議優先順序如下：

1. `squirrel.custom.yaml`
2. 其他手寫的 Rime `*.custom.yaml`
3. McBopomofo 的 `*.txt` 詞庫檔
4. 最後才考慮是否要納入 McBopomofo 的 plist

不建議一開始就把整個 `~/Library/Rime/` 或 `~/Library/Application Support/McBopomofo/` 直接整包納入，因為會混入大量執行時資料。

## Linux Appendix

這裡只補最小必要資訊，不展開 Linux 端排障。

### ibus-rime 設定目錄

根據 Rime wiki，IBus 的使用者資料夾通常是：

- `~/.config/ibus/rime/`

舊版本可能還會看到：

- `~/.ibus/rime/`

### ibus-rime 重新部署

根據 Rime wiki 的 `CustomizationGuide`，如果找不到狀態欄上的 deploy 按鈕，可在終端觸發：

```bash
touch ~/.config/ibus/rime/
ibus restart
```

如果未來這個 repo 要把 Linux 端 Rime 設定一起納管，建議也同樣只從 `*.custom.yaml` 開始，而不是直接處理整個資料夾。

## 參考資料 (References)

- [McBopomofo 使用手冊](https://github.com/openvanilla/McBopomofo/wiki/%E4%BD%BF%E7%94%A8%E6%89%8B%E5%86%8A)
- [Rime CustomizationGuide](https://github.com/rime/home/wiki/CustomizationGuide)
- [Rime RimeWithSchemata](https://github.com/rime/home/wiki/RimeWithSchemata)
- [rime/squirrel#1023](https://github.com/rime/squirrel/issues/1023)
- [rime/home#202](https://github.com/rime/home/issues/202)
- [rime/squirrel#145](https://github.com/rime/squirrel/issues/145)
- [rime/librime#294](https://github.com/rime/librime/issues/294)
- [rime/squirrel#201](https://github.com/rime/squirrel/pull/201)
- [rime/squirrel#1054](https://github.com/rime/squirrel/pull/1054)
- [ShowyEdge](https://github.com/pqrs-org/ShowyEdge/)
