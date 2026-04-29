# tmux — 主題 (Themes)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

兩個主題並列安裝；**Catppuccin 為預設**。

| 主題 | 狀態列 (status bar) | 啟用選項 |
|-------|-----------|---------------|
| Catppuccin（mocha，圓角視窗 (window)）| **頂部** | `@theme_variant = catppuccin`（預設）|
| tmux2k（onedark，含 git / cpu / ram + 頻寬 / 網路 / 時間）| **底部** | `@theme_variant = tmux2k` |

## 主題如何選擇

入口檔 `~/.config/tmux/tmux.conf` 依以下順序解析主題：

1. `TMUX_THEME` 環境變數 (environment variable)（在 tmux 啟動時若有設定）。
2. `@theme_variant` tmux 選項（在伺服器上持續存在直到 `kill-server`）。
3. 備援：`catppuccin`。

每個主題檔皆宣告自己的 TPM 外掛 (plugin)、明確 `run` 該外掛（讓 `prefix + R` 能運作），並在組合自身設定前重置 `status-left/right` + `window-status-format`。

## 切換

### 啟動時的每伺服器設定（shell 端）

```bash
TMUX_THEME=tmux2k tmux        # 以 tmux2k 啟動 tmux
TMUX_THEME=catppuccin tmux    # 以 catppuccin 啟動 tmux
```

便利別名：

```bash
alias tmuxc='TMUX_THEME=catppuccin tmux'
alias tmuxt='TMUX_THEME=tmux2k tmux'
```

### 在執行中的 session 內

| 鍵位 (keybinding) | 動作 |
|------------|--------|
| `prefix + M-c` | 切換到 Catppuccin |
| `prefix + M-t` | 切換到 tmux2k |

兩個項目也可在彈出選單 (popup menu) (`prefix + Space` → `→ Theme`) 中找到。

### 首次注意事項

只有當前啟用的主題的外掛會在 config 載入時宣告給 TPM。當你第一次切換到另一個主題，主題檔的自動 clone hook 會抓取 repo，然後明確的 `run` 才會載入它。如果按下 `prefix + M-c` / `prefix + M-t` 後狀態列仍然怪怪的：

1. 按 `prefix + I` — TPM 會（重新）安裝任何缺少的東西。
2. 為了得到最乾淨的視覺效果（不殘留前一個主題的樣式），請執行 `tmux kill-server && tmux`。

## Catppuccin 狀態列模組

v2 外掛在 `~/.tmux/plugins/tmux/status/` 內提供一組預先建好的模組。可在 `theme.catppuccin.conf` 中以 `#{E:@catppuccin_status_<name>}` 條目附加到 `status-left` / `status-right` 來組合。

| 模組 | 顯示內容 |
|--------|----------------|
| `session` | session 名稱 |
| `directory` | 當前窗格 (pane) 的目錄（用 `@catppuccin_directory_text` 調整）|
| `application` | 作用中窗格的前景命令 |
| `user` | `$USER` |
| `host` | 主機名稱 |
| `date_time` | 日期/時間（用 `@catppuccin_date_time_text` 調整，使用 strftime 格式）|
| `uptime` | 主機運作時間 |
| `cpu` | CPU 負載 |
| `ram` | RAM 用量 |
| `battery` | 電池（筆電；其他情況靜默）|
| `load` | 系統 load average |
| `gitmux` | [gitmux](https://github.com/arl/gitmux) 狀態（需要 `gitmux` 二進位檔）|
| `kube` | kubectl context（需要 `kubectl`）|
| `weather` / `clima` | 天氣（需網路 + `curl`）|
| `pomodoro_plus` | Pomodoro 計時器 |

當前預設值（皆於完整寬度顯示）：

- **左側**：`session` → `directory`
- **右側**：`application` → `user` → `host` → `date_time`

這些模組是**響應式 (responsive)** 的 — 詳見下方 [響應式狀態列](#responsive-status-bar-catppuccin)。

例如要在右側加入 `cpu` 與 `ram`：

```tmux
set -agF status-right "#{E:@catppuccin_status_cpu}"
set -agF status-right "#{E:@catppuccin_status_ram}"
```

實用的旋鈕：

```tmux
set -g @catppuccin_directory_text "#{b:pane_current_path}"   # basename（預設）
set -g @catppuccin_directory_text "#{pane_current_path}"     # 完整路徑
set -g @catppuccin_date_time_text "%Y-%m-%d %H:%M"           # strftime
```

## 響應式狀態列 (Catppuccin)

Catppuccin 主題透過 `~/.config/tmux/responsive.sh` 依終端機 (terminal) 寬度自適應其狀態列模組。一個 `client-resized` hook 會在終端機調整大小時重新執行該腳本，因此從手機終端機到 4K 螢幕都會自動運作。

### 寬度分層

| 寬度（欄）| 分層 | 左側 | 右側 |
|-----------------|------|------|-------|
| >= 120 | wide | session + directory | application + user + host + date_time |
| 80-119 | medium | session + directory | host + date_time |
| < 80 | narrow | session | date_time |

`status-left-length` 與 `status-right-length` 也會隨寬度縮放（分別是 25/40、40/80、60/120），以避免 tmux 預設的截斷限制。

### 為何用 shell 腳本而非純 tmux format 條件式？

Catppuccin 模組的 format 字串內部包含逗號（來自 `#{?client_prefix,red,green}`，作為 prefix 鍵顏色指示器）。把這些巢狀放進另一個 `#{?condition,module,}` 三元式會破壞 tmux 的 format parser，因為它會混淆逗號分隔符。shell 腳本透過為每個模組分別執行 `tmux set -agF` 命令，避開任何 format 巢狀來迴避此問題。

### 主題切換

當從 Catppuccin 切到 tmux2k (`prefix + M-t`) 時，`client-resized` hook 會自動移除（在 `theme.tmux2k.conf` 中的 `set-hook -gu client-resized`）。切回 Catppuccin 時會重新註冊該 hook。

### 自訂分層

編輯 `~/.config/tmux/responsive.sh`（來源：`dot_config/tmux/executable_responsive.sh`）。寬度閾值與模組指派為腳本頂端附近的純 bash `if` 區塊。

## 疑難排解

### Catppuccin 顯示為 tmux 預設綠色狀態列

代表外掛未載入。檢查：

```bash
ls ~/.tmux/plugins/tmux   # 應包含 catppuccin.tmux
```

若缺失，自動 clone 沒有執行（例如首次重新載入時無網路）。修復：

```bash
git clone https://github.com/catppuccin/tmux.git ~/.tmux/plugins/tmux
tmux source-file ~/.tmux.conf
```

或在 tmux 內按一次 `prefix + I`。

### 頻寬欄顯示 `18446744073709551615K`（tmux2k）

那個數字是 `2^64 − 1` — uint64 環繞值。當 tmux2k 的頻寬輔助計算 `previous_counter − current_counter` 而減法產生 underflow 時就會出現。常見觸發：

- tmux2k 自動偵測到的介面沒有流量或消失了（VPN tunnel、`docker0`、橋接介面等）。
- 重新載入或伺服器重啟後第一次刷新時，「上一個 tick」的 cached counter 缺失。

替代方案（任選其一）：

1. **切換到 Catppuccin**：`prefix + M-c` — 預設主題完全不渲染頻寬欄。
2. **釘住介面**於 `dot_config/tmux/theme.tmux2k.conf`：

   ```tmux
   set -g @tmux2k-network-name "en0"       # macOS Wi-Fi
   # set -g @tmux2k-network-name "wlan0"   # 一般 Linux Wi-Fi
   # set -g @tmux2k-network-name "eth0"    # 一般 Linux 有線
   ```

   用 `ip -br link`（Linux）或 `ifconfig` / `networksetup -listallhardwareports`（macOS）找出正確名稱。
3. **移除頻寬欄**：從 `@tmux2k-right-plugins` 移除 `bandwidth`，僅保留 `network time`。

進度可參考上游 [2kabhishek/tmux2k](https://github.com/2kabhishek/tmux2k) 的 issues。

### `sesh connect` 後 status-left 的 session 名稱沒有更新

症狀：透過 `sesh connect`（或任何 `switch-client -t`）切換 session 後，catppuccin 的 status-left 仍顯示舊的 session 名稱，直到你 `tmux detach` + `tmux attach`、手動執行 `tmux refresh-client -S`，或按 `prefix + R` 重新 source config 為止。

原因：catppuccin 的 `@catppuccin_status_session` 模組以 `set -ag`（無 `-F`）儲存其文字片段，將 `#{E:@catppuccin_session_text}`（展開為 `#S`）作為*字串引用*嵌入變數內。當 `responsive.sh` 接著將該變數包進另一個 `#{E:...}` 時，結果是三層巢狀展開，tmux 的 per-client format cache 在 `client-session-changed` 時不會將其失效。已上報為 [catppuccin/tmux#337](https://github.com/catppuccin/tmux/issues/337)（已關閉但 staleness 路徑仍在）。

修復方式（已套用於 `dot_config/tmux/executable_responsive.sh`）：手寫 session 區塊，使用 literal `#S` 加上 catppuccin 的 `@thm_*` 調色盤變數，完全繞過 `@catppuccin_status_session`。directory 與右側模組仍走 catppuccin，因為它們不引用 client 的即時狀態。tmux 在每次狀態列重繪時會重新計算 `#S`，所以切換 session 會立即更新，不需要任何 hooks 或 `refresh-client` 呼叫。

**不**可行的修復變體：加入 `set-hook -g client-session-changed 'refresh-client -S'`，或在 sesh 綁定後追加 `&& tmux refresh-client -S`。兩者皆觸發過早 — `run-shell` 是非同步完成，發生在彈出視窗的 frame 重繪覆蓋 refresh 之後，所以 cached 的 status-left 勝出。手寫做法是唯一能在彈出視窗 race 中存活的修復。

### 切換主題後留下殘餘樣式

某些 tmux 選項（顏色、pane-border-style 等）在外掛設定後仍保留在伺服器上。我們的主題檔在組合前會重置 `status-left/right` 與 `window-status-*`，這涵蓋了可見的狀態列，但更深層的樣式覆寫仍可能殘留。最乾淨的解法：

```bash
tmux kill-server && tmux
```
