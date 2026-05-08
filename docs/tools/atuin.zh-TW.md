# atuin — 神奇的 shell 歷史紀錄

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[atuin](https://atuin.sh) 將你的 shell 歷史紀錄替換成一個 SQLite 資料庫
(database)，記錄每條指令的離開碼 (exit code)、執行時間、工作目錄、主機名稱
與 session。可選用端對端加密 (end-to-end encrypted) 同步跨多台主機。

## 為何採用

- **跨 shell 歷史** — 同一個位於 `~/.local/share/atuin/history.db` 的
  SQLite db，在任何安裝了 atuin 的主機上會同時被 bash 與 zsh 讀取。你昨天
  在 zsh 寫的精緻 `ffmpeg` 一行指令，今天從 bash 用 `Alt+R` 搜尋時就會出現。
- **情境感知過濾 (context-aware filtering)** — atuin 的 TUI（bash 上是
  `Ctrl+R`，zsh 與 bash 上是 `Alt+R`）讓你在選擇器內以 `Ctrl+R` 切換
  全域 / 目前 session / 目前主機 / 目前目錄等範圍。
- **離開碼感知** — 失敗的指令在 TUI 中視覺上有明顯區別。
- **無廠商鎖定 (vendor lock-in)** — 預設僅本機。同步伺服器為可選且可自架。

## 安裝

由 `chezmoi apply` 透過 [`atuin` ansible role](https://github.com/daviddwlee84/dotfiles/tree/main/dot_ansible/roles/atuin/tasks/main.yml) 自動安裝：

| 平台 | 安裝器 | 二進位位置 |
|----------|-----------|-----------------|
| macOS    | `brew install atuin` | `/opt/homebrew/bin/atuin`（Apple Silicon）/ `/usr/local/bin/atuin`（Intel） |
| Linux    | `curl … https://setup.atuin.sh \| sh -s -- --non-interactive` | `~/.atuin/bin/atuin` |

Linux 安裝器以 `ATUIN_NO_MODIFY_PATH=1` 呼叫，因此**不會**動到你的 shell rc
檔。PATH 串接與 `atuin init` 直接由 dotfiles 處理：

- `dot_config/shell/15_atuin.sh` — 共用（zsh + bash）；在 Linux 上將
  `~/.atuin/bin` 加入 PATH，於 zsh 執行 `atuin init zsh`，於 bash 註冊
  `Alt+R` 綁定。
- `dot_bashrc.tmpl` 步驟 8 — 執行 `atuin init bash --disable-up-arrow`
  （up-arrow 由 ble.sh 掌管）。

## 鍵位綁定（跨 shell 不對稱——請務必閱讀）

| 鍵 | Shell | 動作 | 原因 |
|-----|-------|--------|-----|
| `Ctrl+R` | **bash** | atuin TUI | atuin 在 bash 上的預設綁定；行之有年 |
| `Ctrl+R` | **zsh**  | fzf-history-widget（**非** atuin） | 保留 fzf 肌肉記憶與 OMZ 整合 |
| `Alt+R`  | bash + zsh | atuin TUI | 跨 shell 一致——同一鍵在兩者皆開啟 atuin |
| `Up`     | bash | ble.sh history | atuin init 以 `--disable-up-arrow` 啟用 |
| `Up`     | zsh  | OMZ history-substring-search | atuin init 以 `--disable-up-arrow --disable-ctrl-r` 啟用 |

`Ctrl+R` 的不對稱是刻意設計。理由：

- bash 上沒有我們在用的 fzf-history-widget 對應物；atuin 在那邊嚴格更佳，
  因此給它主要鍵位。
- zsh 使用者多年來對 `Ctrl+R` → fzf 已有肌肉記憶，且 fzf 的歷史搜尋能與
  我們其他的 zsh widget（tools-picker、sesh 等，透過 OMZ fzf 外掛）乾淨地
  組合。在此強迫 atuin 占用 `Ctrl+R` 會破壞該整合。
- `Alt+R` 在兩種 shell 上行為一致，且具助記性（**R**ecall）。

若你偏好在所有環境都用 `Ctrl+R` 啟動 atuin（單一 shell 使用者），可編輯
`dot_config/shell/15_atuin.sh` 並從 zsh init 行移除 `--disable-ctrl-r`。

## 預設僅本機

開箱即用時，atuin 以**僅本機模式 (local-only mode)** 運作：歷史紀錄寫入
`~/.local/share/atuin/history.db` 且永不離開該機器。沒有帳號、沒有網路呼叫、
沒有遙測 (telemetry)。

如果你只是想要更精緻的單機歷史搜尋 TUI，到此為止即可。

## 選擇性同步（手動）

若要透過端對端加密同步跨主機共享歷史：

```bash
# 1. Pick a sync server. Either:
#    a) Free tier on api.atuin.sh (default)
#    b) Self-hosted — see https://docs.atuin.sh/cli/self-hosting/

# 2. Register an account (only once, on first host)
atuin register -u <username> -e <email>
# (you'll be prompted for a password and shown your encryption key — SAVE IT)

# 3. On every other host, log in with the same key
atuin login -u <username>
# (paste the encryption key from step 2 when prompted)

# 4. Trigger the first sync
atuin sync
```

**讓憑證 (credentials) 在 `chezmoi apply` 之間保持** — `atuin login` 會將
session 狀態寫到 `~/.local/share/atuin/session`（atuin 自身已將其 gitignore），
伺服器設定則寫到 `~/.config/atuin/config.toml`。兩者都不由 chezmoi 管理，
因此可在重新 apply 後存活。加密金鑰本身在 `login` 之後**不會**以明文形式
存放在磁碟上的任何位置——遺失它就等於失去存取已同步歷史的能力。

若要跨機隊 (fleet) 自動配置（讓新主機免手動提示即可繼承同步），把憑證放到
你的 `secrets.zsh` / `secrets.sh`（未追蹤），並在其中以下列守衛呼叫
`atuin login`：`atuin status | grep -q 'logged in' || atuin login -u … -p … -k …`。

## 匯入既有歷史

```bash
atuin import auto    # auto-detect bash / zsh / fish history files
# or pick one:
atuin import zsh
atuin import bash
```

每台主機跑一次。具冪等性 (idempotent)——重跑不會重複條目。

## 常用子指令

| 指令 | 用途 |
|---------|------|
| `atuin search <query>` | CLI 搜尋（非 TUI；適合腳本使用） |
| `atuin stats` | 最常用指令、每日頻率等統計 |
| `atuin status` | 同步狀態、帳號資訊、db 大小 |
| `atuin sync` | 立即強制同步 |
| `atuin doctor` | 診斷安裝 / 設定問題 |
| `atuin update` | 自我升級（Linux 安裝器路徑；macOS 走 brew） |

## 升級

| 主機 | 路徑 |
|------|------|
| macOS | `brew upgrade atuin`（由 `just upgrade-brew` 涵蓋） |
| Linux | `just upgrade-atuin` → `atuin update`（失敗時回退至重跑 `setup.atuin.sh`） |

`just upgrade-all` 透過分類分派 (categorised dispatch) 同時涵蓋兩者。

## 相關

- [Zsh keybindings & keys-picker](../shells/keybindings.md) — 完整的 repo
  全域鍵位綁定表；atuin 的 `Alt+R` 綁定也記載於該處。
- [Emacs-style line editing origin](../shells/emacs-line-editing.md) — 為什麼
  `Ctrl+R` 在最初就是「反向搜尋 (reverse search)」的鍵
  （Readline 血統）。
- [Bash bootstrap](../shells/bash.md) — 載入順序；atuin init 在步驟 8 執行，
  在 `15_atuin.sh` 被 `load_modular_dir`（步驟 7）source 之後，因此
  `Alt+R` 透過 `PROMPT_COMMAND` 進行延遲綁定 (deferred-bind)。
- [Shell history reference](../shells/history.md) — bash/zsh 原生歷史檔、
  環境變數、伺服器上的多使用者稽核 (audit)，以及 atuin 的 SQLite 儲存
  與純文字檔之間的關係。
- 上游文件：<https://docs.atuin.sh>
- 上游 repo：<https://github.com/atuinsh/atuin>
