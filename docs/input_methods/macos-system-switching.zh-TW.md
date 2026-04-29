# macOS 系統層級輸入來源切換 (Input Source Switching)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

整理目前在 macOS 上管理 input source 切換的幾種常見方案，重點是：

- 不依賴 Rime / Squirrel 內建的 `app_options` 或 `vim_mode`
- 直接操作 macOS 的 input source layer
- 回答兩個實際問題：
    - 能不能維持「全域一致」？
    - 能不能做到「特定 app 預設輸入法」？

查閱日期：`2026-03-31`

## TL;DR

### Apple 原生能做到什麼

Apple 官方目前明確文件化的原生能力主要是：

- 顯示 input menu
- 用 `Caps Lock` 在 non-Latin 與「last used Latin input source」間切換
- 用 `Fn` / `Globe` 或快捷鍵切換 input source
- 記住「每個文件」的 input source

最重要的原生選項在：

- `System Settings > Keyboard > Text Input > Edit > Automatically switch to a document's input source`

Apple 的描述是：同一個文件在關閉前，會記住自己的 input source。
所以如果目標是「盡量全域一致」，通常應先把這個選項關掉。

### Apple 原生做不到什麼

我沒有找到 Apple 官方文件化的「per-app 預設輸入法」功能。這裡的結論是根據目前 Apple 文件可見內容做的推論，不是 Apple 明文說「絕對不支援」。

換句話說：

- `全域一致`：Apple 原生可部分改善
- `特定 app 預設`：目前看不到 Apple 原生正式支援

## 方案總覽

| 方案 | 操作層級 | 全域一致 | per-app 預設 | 備註 |
| --- | --- | --- | --- | --- |
| Apple 原生設定 | 系統內建 | 部分可行 | 不明顯支援 | 先關閉 per-document 記憶 |
| Input Source Pro | 系統層 app 規則 | 可 | 可 | 成品最完整 |
| Hammerspoon | 系統層自動化 | 可 | 可 | 開源，可自訂規則 |
| Keyboard Maestro / BetterTouchTool | 系統層自動化 | 可 | 可 | 適合已有自動化棧的使用者 |
| `macism` | CLI backend | 不是完整方案 | 可被上層調用 | 適合搭配 Hammerspoon / KM / BTT |
| `im-select` | CLI backend | 不是完整方案 | 可被上層調用 | macOS 上對 CJK 切換可靠性較弱 |
| Karabiner-Elements | 快捷鍵 / 改鍵 | 不擅長 | 不擅長 | 官方直接提醒 CJKV 可能失敗 |

## 1. Apple 原生設定

參考：

- [Change Input Sources settings on Mac - Apple Support](https://support.apple.com/guide/mac-help/change-input-sources-settings-mchl84525d76/mac)

Apple 目前明確列出的相關選項有：

- `Show Input menu in menu bar`
- `Use the Caps Lock key to switch to and from [last used Latin input source]`
- `Automatically switch to a document's input source`
- `Fn` / `Globe` key 切換 input source

### 適合的用法

如果目標是減少狀態混亂，先做這兩件事：

1. 關掉 `Automatically switch to a document's input source`
2. 開啟 menu bar input menu，保留可見性

### 能力邊界

- 可改善「切文件之後狀態突然不同」的情況
- 不能直接表達「Terminal 一律 ABC、WeChat 一律注音」這種 app rule

所以原生設定比較像是：

- 收斂全域行為
- 但不是 app-aware rule engine

## 2. Input Source Pro

參考：

- [Input Source Pro 官網](https://inputsource.pro/)
- [Input Source Pro Changelog](https://inputsource.pro/changelog)
- [runjuu/InputSourcePro](https://github.com/runjuu/InputSourcePro)

這是目前最接近「現成可用 app 規則系統 (rule system)」的方案。

官網明列能力：

- 根據 app 自動切換 input source
- 根據網站自動切換 input source
- 顯示目前 input source
- 在 IDE / Terminal 類 app 強制英文標點

截至 `2026-01-18` 的 `2.9.0` changelog 也還在持續改善 switching logic consistency。

### 優點

- 成品完整，不需要自己寫 watcher
- 明確支援 per-app 預設
- 還有可見性與標點規則

### 缺點

- 不是系統內建
- 如果你想把規則版本化進 dotfiles，不如 Hammerspoon 直觀

### 適合誰

- 想最快得到「app 切換時自動切輸入法」
- 不想自己維護 Lua / AppleScript / shell glue

## 3. Hammerspoon

參考：

- [InputSourceSwitch Spoon](https://www.hammerspoon.org/Spoons/InputSourceSwitch.html)
- [hs.keycodes](https://www.hammerspoon.org/docs/hs.keycodes.html)

Hammerspoon 是最適合做「自己掌控規則，但又保持在 macOS input source layer」的開源方案。

官方現成的 Spoon `InputSourceSwitch` 已直接支援：

- 切 app 時自動切換 input source

範例如下：

```lua
hs.loadSpoon("InputSourceSwitch")
spoon.InputSourceSwitch:setApplications({
  ["WeChat"] = "Pinyin - Simplified",
  ["Mail"] = "ABC",
})
spoon.InputSourceSwitch:start()
```

如果不想只靠 Spoon，也可以自己用 `hs.keycodes.currentSourceID([sourceID])` 讀寫目前的 input source，自己綁 app watcher 或 window watcher。

### 優點

- 開源
- 規則可版本控制
- 可以做得很細，例如：
    - app activated 時切換
    - 只對某些視窗標題切換
    - 額外加 menubar / alert 指示

### 缺點

- 要自己維護設定
- 如果底層切換本身遇到 macOS/CJK 問題，仍可能需要更可靠的 CLI backend

## 4. Keyboard Maestro / BetterTouchTool

參考：

- [Keyboard Maestro Application Trigger](https://wiki.keyboardmaestro.com/trigger/Application)
- [Keyboard Maestro Execute a Shell Script](https://wiki.keyboardmaestro.com/action/Execute_a_Shell_Script)
- [BetterTouchTool Global and App-Specific Triggers](https://docs.folivora.ai/docs/configuration/global-vs-app-specific/)

這兩者都不是專用 input source 工具，但都能做出「app activated -> 執行 script -> 切輸入法」的流程。

### Keyboard Maestro

Keyboard Maestro 官方文件明確支援：

- application activates / deactivates trigger
- Execute a Shell Script action

所以可以做：

1. App Activate Trigger
2. 呼叫 `macism` 或其他 CLI
3. 切到指定 input source

### BetterTouchTool

BetterTouchTool 官方文件明確支援：

- global triggers
- app-specific triggers
- conditional activation groups

它本身不是專門的 input source 切換器，但如果你本來就有 BTT，自動化入口已經足夠，只差底層切換命令。

### 什麼時候選這條路

- 你本來就在用 KM / BTT
- 想把輸入法切換跟其他 workspace automation 合併
- 不想再引入一套新的整體框架

## 5. CLI backend：`macism` 與 `im-select`

這兩個通常不是完整解法，而是給上層工具調用的切換 backend。

### `macism`

參考：

- [laishulu/macism](https://github.com/laishulu/macism)

`macism` README 的核心主張是：

- 它比 `im-select` 等類似工具更可靠地切換 CJKV input source
- 其他工具有時會出現 menu bar icon 已變，但實際輸入來源沒真的切過去的情況

這個專案也直接提供：

- 取得目前 input source
- 設定指定 input source
- 內建 workaround for the macOS bug

如果你要自己用 Hammerspoon / Keyboard Maestro / BetterTouchTool 拼裝，我會優先考慮 `macism`。

### `im-select`

參考：

- [daipeihust/im-select](https://github.com/daipeihust/im-select)

`im-select` 是常見方案，很多 Vim / VSCodeVim 設定都支援它。

但如果你的核心場景是：

- 中文 / 日文 / 韓文 / 越南文等 CJKV input source
- 要求切換後立即可靠生效

那目前資料更偏向：

- `im-select` 可用
- 但 macOS 上 CJK 切換可靠性通常不如 `macism`

## 6. Karabiner-Elements

參考：

- [to.select_input_source](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to/select-input-source/)

Karabiner 很適合做：

- 快捷鍵綁定
- 依 input source 條件改鍵
- 送出切換快捷鍵

但不適合當這題的主方案。

Karabiner 官方文件直接提醒：

- 對有 `input_mode_id` 的輸入法，例如 CJKV，`select_input_source` 可能因 macOS 問題失敗
- 對 CJKV，官方甚至建議送出 input source switch shortcut，例如 `control-space`

所以它比較適合：

- 做 hotkey
- 做狀態條件
- 當輔助層

而不是當主要的 per-app input source manager。

## 推薦路線

### 路線 A：最少折騰

適合先驗證問題是不是主要來自 macOS 的 per-document 行為。

1. 關掉 `Automatically switch to a document's input source`
2. 保留 menu bar input menu 或其他 indicator
3. 先觀察是否已經大幅減少混亂

### 路線 B：想要每個 app 自動切到指定輸入法

首選：

- Input Source Pro

原因：

- 這是目前最完整的成品
- 有 app rules
- 有 indicator
- 有 terminal / IDE 標點類附加功能

### 路線 C：想要開源、可版本控制、可放進 dotfiles

首選：

- Hammerspoon + `macism`

原因：

- Hammerspoon 負責 watcher / 規則
- `macism` 負責較可靠的底層切換
- 最適合 repo 化與長期維護

### 路線 D：你本來就重度使用 KM / BTT

首選：

- Keyboard Maestro / BetterTouchTool + `macism`

原因：

- 不需要再多引入一套自動化邏輯
- 直接掛在既有 app activate trigger 上

## 與 Rime / Squirrel 的關係

這些方案的共同點是：

- 目標是從 macOS input source layer 管理切換
- 不依賴 Squirrel 的 `app_options` 或 `vim_mode`

因此比較適合處理：

- app 切換時想要固定英文 / 固定中文
- 想降低「現在到底是什麼輸入狀態」的不確定感

但要注意：

- 如果底層 macOS 對某些 CJK input source 本身就有切換 bug，任何方案都可能只是在不同程度上繞過它
- 所以實務上，`system automation layer + visible indicator` 往往比只追求「自動切換」更穩

## 參考資料 (References)

- [Apple Support: Change Input Sources settings on Mac](https://support.apple.com/en-afri/guide/mac-help/mchl84525d76/26/mac/26)
- [Input Source Pro](https://inputsource.pro/)
- [Input Source Pro Changelog](https://inputsource.pro/changelog)
- [runjuu/InputSourcePro](https://github.com/runjuu/InputSourcePro)
- [Hammerspoon InputSourceSwitch Spoon](https://www.hammerspoon.org/Spoons/InputSourceSwitch.html)
- [Hammerspoon hs.keycodes](https://www.hammerspoon.org/docs/hs.keycodes.html)
- [laishulu/macism](https://github.com/laishulu/macism)
- [daipeihust/im-select](https://github.com/daipeihust/im-select)
- [Karabiner-Elements: to.select_input_source](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to/select-input-source/)
- [Keyboard Maestro: Application Trigger](https://wiki.keyboardmaestro.com/trigger/Application)
- [Keyboard Maestro: Execute a Shell Script](https://wiki.keyboardmaestro.com/action/Execute_a_Shell_Script)
- [BetterTouchTool: Global and App-Specific Triggers](https://docs.folivora.ai/docs/configuration/global-vs-app-specific/)
