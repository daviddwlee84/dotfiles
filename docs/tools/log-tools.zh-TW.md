# Log Viewers — 給 `.log` 檔案的彩色工具帶

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

在終端機讀 server/app log 應該要跟 `bat` 讓讀程式碼一樣愉快。
這個 repo 提供四個互補的工具 — 各自解決「讀、跟隨、搜尋、上色」這個問題的不同層面 —
再加上 zsh wrapper 與一個 Television channel 把它們串起來。

四個工具都會由 `devtools` Ansible role 安裝
（見 [`dot_ansible/roles/devtools/tasks/main.yml`](../../dot_ansible/roles/devtools/tasks/main.yml)）。
`tailspin`/`lnav`/`grc` 在 macOS 走 Homebrew、在 Debian/Ubuntu 走 apt；
`lnav` 與 `tailspin` 在 Linux 上還有 user-level 的 GitHub-release musl-binary fallback
（含無 sudo 的 shell）。`ccze` 是 **Linux-only** — 已從 Homebrew core 移除，
所以 macOS 上 `lessl` wrapper 會優雅地 no-op，你應該改用 `tspin`。

## TL;DR

| 工具 | 最適場景 | 命令形式 | 備註 |
|---|---|---|---|
| [`tailspin`](https://github.com/bensadeh/tailspin)（bin: `tspin`） | **一次性上色** / log 版的 `bat` | `tspin file.log`（pager）· `… \| tspin --print`（pipe） | 零組態 (configuration)。會 highlight 日期、log level、IP、URL、數字。對任意文字都管用。 |
| [`lnav`](https://lnav.org/) | **互動式 TUI** | `lnav file.log [file2.log …]` | 合併多檔的時間軸、對 log 資料做 SQL 查詢、內建 filter。認真的選項。 |
| [`grc`](https://github.com/garabik/grc) | **自訂 regex 規則** | `grc -es tail -f app.log` | 每個命令各自的上色設定檔放在 `~/.grc/conf.*`。當你能掌控 log 格式時最好用。 |
| [`ccze`](https://github.com/cornet/ccze) | **輕量級 pipe colorizer** | `ccze -A \| less -R` | 古老但快；經典的 `tail -f \| ccze` pager 寫法。**Linux-only**（從 brew 移除）。 |

判斷原則：

- **就是想立刻有顏色？** → `tspin`（或下方的 `catl` / `logtail` wrapper）。
- **要在多個檔案或時間戳間追事件？** → `lnav`。
- **有自訂 log 格式而且每次跑都想要顏色？** → `grc` profile。
- **習慣 `ccze`、不需要更多？** → `lessl`（我們的 `ccze -A | less -R` wrapper）。

## Zsh wrappers（[`dot_config/zsh/tools/29_log_tools.zsh`](../../dot_config/zsh/tools/29_log_tools.zsh)）

每個 wrapper 都會檢查底層 binary 是否存在，所以全新機器上也安全：

| 命令 | 展開為 | 用途 |
|---|---|---|
| `catl file.log` | `tspin --print file.log` | log 的彩色 `cat`。stdout 模式，可組合 pipe（`catl app.log \| rg ERROR`）。 |
| `lessl file.log` | `ccze -A < file.log \| less -RSFX` | 經典 pager 加 ANSI 顏色。沒給參數時接受 stdin（`tail -f app.log \| lessl`）。 |
| `logtail file.log` | `tspin --follow file.log`（或在較舊 tailspin 上 `tail -F … \| tspin --print`） | 即時跟隨並 highlight — `tail -f` 的取代品。 |

已登記在 [`docs/zsh/aliases.md`](../zsh/aliases.md) 的 "Log Viewers" 區塊。

## `tailspin`（`tspin`）

> "bat for logs."。零組態的 regex-based highlighting，對任何文字流都管用。

**它會自動上色的內容**：日期/時間、log level（`INFO`/`WARN`/`ERROR`/…）、
數字、IP 位址、UUID、URL、HTTP method 與 status code、檔案路徑、加引號字串、key-value pair、常見識別子。

**使用模式**：

```bash
tspin app.log               # 用 less(1) 開帶色輸出，支援搜尋
tspin --follow app.log      # 像 tail -f，即時 highlight
tail -f app.log | tspin     # 透過 stdin 跟隨
rg ERROR app.log | tspin --print   # pipe 友善的 stdout 模式
```

可透過 `~/.config/tailspin/config.toml` 自訂（keywords / regex groups / 停用樣式）；
flag 例如 `--words` 與 `--no-builtin-keywords` 見 `tspin --help`。

**整合範例**。`pueue` Television channel 預覽
（[`dot_config/television/cable/pueue.toml`](../../dot_config/television/cable/pueue.toml)）
在可用時會把每個任務的 log 透過 `tspin --print` pipe 過去：

```toml
command = [
  "if command -v tspin >/dev/null 2>&1; then \
     pueue log '{split:\\t:0}' --lines 200 2>/dev/null | tspin --print; \
   else \
     pueue log '{split:\\t:0}' --lines 200 2>/dev/null; \
   fi || echo 'No log available for: {split:\\t:0}'",
]
```

`if command -v …` 的保護表示 channel 在 `devtools` role 還沒跑前的全新機器上仍然能用。

## `lnav` — Logfile Navigator

重型選項。一個能理解常見 log 格式（syslog、Apache/nginx、systemd journal、JSON、
通用帶時戳行）的終端機 TUI，可把多個檔案合併成一條時間軸，
並對解析後的 log 跑臨時 SQL 查詢。

**重點**：

| Key / 命令 | 作用 |
|---|---|
| `lnav file1.log file2.log …` | 開啟檔案（依時戳合併） |
| `q` | 離開 |
| `/pattern` | 向前搜尋（regex） |
| `?pattern` | 向後搜尋 |
| `n` / `N` | 下一筆 / 上一筆搜尋結果 |
| `:filter-in <re>` / `:filter-out <re>` | 即時過濾 |
| `;SELECT …` | 對解析後 log records 跑 SQL |
| `Shift+P` | 切換 JSON pretty-print |
| `t` | 時間視圖（log 量直方圖） |
| `:goto <time>` | 跳到指定時戳 |

**自訂格式**。當 Debian apt 版本太舊、或你的 app 寫了自訂格式時，
把一個 JSON 格式檔丟到 `~/.lnav/formats/installed/`
（見 [lnav format docs](https://docs.lnav.org/en/latest/formats.html)）。
我們在 Linux 的 fallback 會把 GitHub releases 上最新的 musl 版安裝到 `~/.local/bin/lnav`，
所以即使在較舊發行版上也能拿到夠新的版本。

## `grc` — Generic Colouriser

以 pipe 為主的 colorizer，搭配可由使用者編輯的 regex 規則集。
`tailspin` 給你一套對所有文字都套用的固定預設，`grc` 則讓你按命令定義顏色。

```bash
grc -es tail -f /var/log/nginx/access.log
grc -c /path/to/custom.conf kubectl logs -f my-pod
```

`-e` 停用預設的 `stderr` 合併；`-s` 加上顏色（相對於 `-c` 指定特定 config）。

**設定你自己的 profile**。Python / FastAPI 堆疊的範例：

```conf
# ~/.grc/conf.uvicorn
# colorize `uvicorn` + FastAPI access logs
regexp=(?<=^INFO:\s+)\S+
colour=cyan
count=more
-
regexp=(\s)(ERROR|CRITICAL)(\s)
colours=default,bold red,default
count=more
-
regexp=(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})
colour=dark gray
count=more
-
regexp=(\s)(4\d\d)(\s)
colours=default,yellow,default
count=more
-
regexp=(\s)(5\d\d)(\s)
colours=default,bold red,default
count=more
```

接著：`grc -c ~/.grc/conf.uvicorn uvicorn app:app`。系統內建規則集放在
`/usr/share/grc/` — 把任何一份複製到 `~/.grc/` 即可覆蓋。

如果你想把自己的 profile 納入 dotfiles 追蹤，丟到 `dot_grc/conf.<name>`
（新的 chezmoi source 目錄，目前還沒附上 — 等你定下一個滿意的版本再跟進）。

## `ccze` — 老派 Pipe Colorizer

快、最小、用 C 寫的。上游已沉寂多年；套件仍在 Debian/Ubuntu apt repo 中，
但已 **從 Homebrew core 移除**，所以在 macOS 上實質退役 — 那邊請改用 `tspin --print`。
在 Linux 仍能正常運作。主要寫法：

```bash
tail -f /var/log/syslog | ccze -A | less -R
# 或透過我們的 wrapper
tail -f /var/log/syslog | lessl
```

`-A` flag 輸出原始 ANSI escape（`less -R` 必需）；不加它的話 `ccze` 會試圖接管終端機。
適合處理單純的 syslog / Apache / sulog 來源；對現代結構化／JSON log 沒 `tailspin` 聰明。

## 為什麼沒有 Loguru / logger-internals 的 wrapper？

考慮過一個替代方案：把 Python 的 [Loguru](https://github.com/Delgan/loguru) 或標準函式庫
`logging` 模組包一個漂亮的 handler，讓 Python 腳本永遠都吐彩色輸出。被否決的理由：

1. **層級錯了**。上面那些檢視端工具對任何來源都管用 — 不只 Python — 所以不必每種語言都接受。
2. **侵入性**。每個腳本或 service 都得 import 那個 wrapper；運維人員對別人寫的程式碼沒這個權限。
3. **Loguru 在接到 TTY 時本來就會上色**。難搞的情況（tail 既有的 `.log` 檔、
   journalctl 輸出、nginx access log）都是事後產出，需要的是檢視端工具。

讓 logging library 保持無聊，把顏色放到檢視端。

## Television 整合

兩個切入點：

1. **新的 `logs` channel** —
   [`dot_config/television/cable/logs.toml.tmpl`](../../dot_config/television/cable/logs.toml.tmpl)
   （chezmoi template；journalctl 那一段只在 Linux 渲染）。
   `tv logs` 模糊搜尋 `$PWD`、使用者/系統 log 目錄，以及（僅 Linux）最近的 `journalctl` 輸出中的
   `.log`/`.ndjson`/`.jsonl` 檔。預覽會切換：tailspin 上色的 tail 與純 `bat`。
   Keybindings：
   - `Enter` → 用 `lnav` 開（fallback：`ccze -A | less -R`，再 fallback：純 `less`）
   - `Alt+T` → `tspin --follow` 即時跟隨
   - `Alt+E` → 在 `$EDITOR` 中開啟
   - `Ctrl+Y` → 複製檔案路徑（透過 SSH 的 OSC-52）
2. **`pueue` channel 預覽改寫** — [`pueue.toml`](../../dot_config/television/cable/pueue.toml)
   的任務 log 現在在可用時會 pipe 給 `tspin --print`。

完整 Television channel 列表見 [`docs/tools/tv.md`](tv.md)。

## 參考資料

- [tailspin README](https://github.com/bensadeh/tailspin) — 自訂、keyword 設定
- [lnav user manual](https://docs.lnav.org/) — 格式、SQL、keybindings
- [grc on GitHub](https://github.com/garabik/grc) — `conf.*` 檔案語法
- [ccze on GitHub](https://github.com/cornet/ccze) — 老但好用
- [我們的 aliases 參考](../zsh/aliases.md#log-viewers) — `catl`/`lessl`/`logtail`
