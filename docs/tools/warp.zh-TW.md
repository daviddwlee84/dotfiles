# Warp Terminal

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> AI 原生終端機 (AI-native terminal)。本頁主要說明 **Warp 在各平台上如何更新自己**——以及為何它貼到你 prompt 中的其中一個步驟看起來很可疑。

## 本倉庫如何安裝 Warp

| 平台 | 來源 | 設定位置 | 升級路徑 |
|---|---|---|---|
| macOS | Homebrew cask `warp` | [`dot_config/homebrew/Brewfile.darwin.tmpl`](../../dot_config/homebrew/Brewfile.darwin.tmpl) | `just upgrade-brew`（cask `--greedy`） |
| Ubuntu / Debian | Warp 自己的 apt repo (`https://releases.warp.dev/linux/deb stable main`) | 手動安裝一次；Warp 的 `.deb` postinst 會將 repo 檔放入 `/etc/apt/sources.list.d/warpdotdev.list` | `just upgrade-warp`（apt `--only-upgrade`）——詳見 [§ `cat_warp` 的運作方式](#how-cat_warp-works) |
| 其他 Linux | 不管理 | — | — |

兩條路徑都會被 `just upgrade-all` 涵蓋。Linux 路徑會替換磁碟上的執行檔，但**不會**重啟正在執行的 Warp 程序——你必須退出並重新啟動 Warp 才能載入新版本。為何不能自動重啟：詳見 [§ Ubuntu 應用程式內的更新流程](#the-ubuntu-in-app-update-flow)。

## Ubuntu 應用程式內的更新流程

當 Warp UI 顯示「Update available」時，它會把以下指令注入**到你目前活躍的終端機 prompt**，並等你按下 Enter：

```bash
sudo apt update && sudo apt install warp-terminal && warp_finish_update <token>
```

token（例如 `AgStYNT`）每次更新都會重新生成且不能重複使用。

### 各步驟的作用

#### 1. `sudo apt update`

刷新 apt index。其中比較有趣的是 Warp 自己的 repo：

```text
deb [arch=amd64 signed-by=/usr/share/keyrings/warpdotdev.gpg] \
  https://releases.warp.dev/linux/deb stable main
```

由原始的 `.deb` postinst 放在 `/etc/apt/sources.list.d/warpdotdev.list`。

#### 2. `sudo apt install warp-terminal`

因為套件已經安裝，這**實際上**等同於 `apt install --only-upgrade warp-terminal`——apt 解析候選版本、發現有較新版本可用，然後升級。新的執行檔會落在 `/opt/warpdotdev/warp-terminal/`。目前**正在執行的 Warp 程序尚未受影響**——它仍在執行記憶體中舊的執行檔映像 (binary image)。

#### 3. `warp_finish_update <token>`——非顯而易見的步驟

這是讓人困惑的部分。`warp_finish_update` **不是**系統執行檔，不在任何 apt 套件中，活躍的 Warp session 之外也不在 `$PATH` 上。它是 Warp 在啟動 session 時**注入到你 shell 環境**中的一個 shell function（或 wrapper）——這項權限 Warp 有資格執行，因為它是承載你 shell 的終端機。

它的作用：

1. 解析 unix-socket / IPC 通道，連回仍在執行的 Warp daemon 程序。
2. 將 token 作為握手 (handshake) 送出。token 必須與 Warp 貼出指令時生成的相符，否則該呼叫會被拒絕。
3. daemon 驗證 token、確認 `apt` 已乾淨完成（`&&` 串接保證了這一點——若 `apt install` 回傳非零，`warp_finish_update` 永遠不會執行），然後觸發自身重啟，從 `/opt/warpdotdev/warp-terminal/` 載入剛安裝好的執行檔。

之所以要這樣繞一圈：在 Linux 上，替換磁碟上的執行檔不會替換正在執行的程序。沒有 IPC 握手的話，你就得手動 `pkill warp-terminal`（會失去所有 tab / pane / agent 脈絡）才能讓新版實際載入。token 流程把它變成優雅的重啟。

### 為何 Warp 能貼東西進你的 prompt

Warp 是終端機模擬器 (terminal emulator)，因此控制了它為你的 shell 配置的 PTY 的輸入緩衝區。從 shell 的角度來看，這些按鍵與你親自輸入沒有差別。這也是 Warp 的「AI suggestion → editable command」UX 背後的相同機制。沒有 `expect` / `send` / 權限提升——這只是終端機本地的 I/O。

## macOS 流程（作為對照）

在 macOS 上，Warp 是位於 `/Applications/Warp.app` 下的 `.app` bundle。Sparkle 風格的更新器會從 `https://releases.warp.dev/stable/v<version>/Warp.dmg` 下載新的 `Warp.dmg`、掛載、替換 bundle、重新啟動。沒有 `warp_finish_update` 步驟，因為：

- macOS 上「執行中的 app vs 磁碟上的 app」的 OS 層級語意不同——Cocoa 應用程式可以透過標準的更新器交接 (hand-off) helper 進行 hot-swap，不需要 IPC 握手。
- Cask 安裝走 Homebrew 的 `brew upgrade --cask --greedy`（由 [`upgrade-brew`](../this_repo/upgrades.md#category-matrix) 涵蓋），所以本倉庫在使用時，應用程式內的更新器大多是多餘的。

## `cat_warp` 的運作方式

[`scripts/upgrade_tools.sh`](../../scripts/upgrade_tools.sh) 中的 `warp` 類別執行應用程式內流程的 **apt 一半**——但永遠不執行 `warp_finish_update`，因為它在活躍的 Warp session 之外無法使用（token 是 per-session 的且該 function 不在 `$PATH` 上）：

```bash
sudo apt-get update \
  && sudo apt-get install --only-upgrade -y warp-terminal
```

操作細節：

- **僅限 Linux。**在 macOS 上該類別會以 `SKIPPED` 短路，因為 `cask "warp"` + `brew upgrade --cask --greedy`（由 `cat_brew` 涵蓋）已經負責處理了。
- **`warp-terminal` 不存在時跳過。**回傳 `77` 讓升級摘要將其標記為 SKIPPED 而非 FAILED——沒在跑 Warp 的機器不會被懲罰。
- **重用 sudo session。**呼叫 `sudo_session_init "upgrade-warp"`，因此會共用先前類別（特別是 macOS 上的 `cat_brew`，或任何更早使用 sudo 的步驟）所快取的票證 (ticket)。當 sudo 處於 `non-interactive` 且非 passwordless 時，該類別會自我跳過而不是卡住——詳見 [sudo-session 不變式](../this_repo/sudo-session.md)。
- **重啟由使用者負責。**apt 成功取代 `/opt/warpdotdev/warp-terminal/...` **不會**換掉執行中程序在記憶體裡的執行檔。該類別會記錄一條 `[INFO]` 提醒；你必須退出並重新啟動 Warp，新版本才會生效。
- **Repo 簽章漂移 (signature drift)。**Warp 偶爾會輪換簽章金鑰；若 `apt update` 出現 `NO_PUBKEY` 錯誤，請從 `https://app.warp.dev/download` 取得最新金鑰，重新匯入到 `/usr/share/keyrings/warpdotdev.gpg`。本倉庫並未預先固定金鑰。

獨立執行：

```bash
just upgrade-warp           # 僅執行此類別
just upgrade-all            # 包含於標準鏈中（介於 flatpak 與 agents 之間）
just upgrade-dry-run        # 看看它會執行什麼
```

## 另見

- [`docs/this_repo/upgrades.md`](../this_repo/upgrades.md)——明確的升級流程如何架構；讓 apt 不進入預設範圍的「安裝 vs 升級」規則。
- [`docs/this_repo/sudo-session.md`](../this_repo/sudo-session.md)——任何未來 `cat_warp` 都會使用的共享 sudo helper。
- [`docs/this_repo/instant-llm-fix-prior-art.md`](../this_repo/instant-llm-fix-prior-art.md)——將 Warp 的 AI 功能與本倉庫 `aifix` / `aiblock` 流程的設計空間 (design-space) 比較。
