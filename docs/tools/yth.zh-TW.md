# yth — 搜尋你的 YouTube 觀看歷史

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`yth` 是一個 local-first 的 CLI + Television (`tv`) picker，用來搜尋你自己的 YouTube 觀看
歷史。YouTube 內建的 `/feed/history` 搜尋只能比對標題；`yth` 把 **標題、頻道、描述、字幕
(caption) 文字** 都建進本機的 sqlite 資料庫，用 FTS5 搜尋——所以「我記得看過某個關於 X 的
影片」就變成一行查詢。這是與 `mlf` + `tv mlflow`、[`fleet hosts`](fleet-hosts.md)
相同的 gh-select 式雙介面模式。

Binary：`dot_dotfiles/bin/executable_yth`（→ `~/.dotfiles/bin/yth`）。模組：`scripts/yth/`。
Picker 雙胞胎：`tv yth`（`dot_config/television/cable/yth.toml`）。

## 安裝 (Install)

由 chezmoi 自動部署：

- `yth` 透過 `uv run --script` shebang（PEP 723 inline metadata 宣告 `yt-dlp`、`tyro`、
  `rich`、`platformdirs`）自我 bootstrap Python 依賴——不需額外安裝步驟。
- `yt-dlp` **同時** 由 `python_uv_tools` ansible role 安裝為獨立 binary（與 `mlflow` ↔
  `mlf` 相同的雙重模式），所以 `yt-dlp` 也獨立在 PATH 上。
- 需要 PATH 上有 `uv`；`tv yth` preview pane 需要 `bat`；`ffmpeg`（`media_tools` role 已裝）
  為選配（僅 muxing 用，`yth` 不做）。

## 兩個資料源 (data sources)，以及原因

你的觀看歷史 **不在** YouTube Data API 裡（約 2016 移除）。`yth` 用兩種方式取得：

| 來源 | 指令 | 需要 cookie？ | 涵蓋範圍 | 時間戳 |
|---|---|---|---|---|
| **Google Takeout**（主要） | `yth import-takeout <file>` | 否 | 完整多年歷史 | 精確（來自匯出檔） |
| **yt-dlp `:ythistory`**（次要） | `yth sync` | **是** | 僅近期可分頁載入的視窗 | 近似（sync 當下時間） |

從 [Google Takeout](https://takeout.google.com/) → *YouTube and YouTube Music* → history →
選 **JSON** 格式 → `watch-history.json`。匯入是 idempotent：重複匯入同一份（或有重疊的）匯出
檔不會新增任何東西。`sync` 用於兩次匯出之間的快速增量補充；Takeout 永遠是真相來源
(source of truth)。

## 快速開始 (Quick start)

```bash
yth import-takeout ~/Downloads/watch-history.json   # 回填 (cookie-free)
yth enrich --limit 500                              # 補描述/時長（公開影片）
yth fetch-subs --recent 100                         # 為近期影片建立字幕索引
yth search "rust async"                             # 搜尋標題/頻道/描述
yth search "borrow checker" --subs                  # 也搜尋字幕文字
tv yth                                              # 對整個歷史做 fuzzy 挑選
```

## 子指令 (Subcommands)

| 指令 | 作用 |
|---|---|
| `import-takeout <file>` | 從 Takeout `watch-history.json` 回填（僅 JSON）。Idempotent。 |
| `sync [--limit N] [--full]` | 增量 `:ythistory` 同步（需要 cookie）。從最新往 cursor 走。 |
| `enrich [--limit N \| --all] [--cookies] [--force]` | 抓 title/description/duration/upload_date。公開影片免 cookie。永久性失敗（移除/私人）會 stamp；暫時性（bot-check/429）下次重試。 |
| `fetch-subs <id>… \| --recent N \| --all [--cookies] [--langs …]` | 下載手動+自動字幕，VTT→純文字，建索引。 |
| `search <query> [--subs] [--json] [--limit N] [--raw]` | FTS5 搜尋。`--subs` 也比對字幕；`--raw` 用原生 FTS5 語法。 |
| `list [--tsv] [--limit N]` | 最新在前列出歷史。`--tsv` 是 `tv yth` 的 source。 |
| `show <id> [--json]` | 單一影片詳情（僅讀 DB，不連網）。tv preview 由此驅動。 |
| `open <id>` / `copy <id>` / `play <id>` | 瀏覽器開啟 / 複製 URL / 播放（有設定 mpv 則用 mpv，否則瀏覽器）。 |

## YouTube runtime + Cookie（僅 `sync` + 受限影片）

**公開影片不需要 cookie**——`enrich` 與 `fetch-subs` 會使用隨套件安裝的
`yt-dlp-ejs` 加上本 repo 管理的 Node 22+ runtime，應可免登入運作。舊 armv7/armv6
的 Node 20 與 EL7 的 Node 16 不會被誤選成 EJS runtime；doctor 會明確回報平台限制。只有帳號私有的
`yth sync` 與私人／受限內容本質上需要 cookie；完整歷史仍優先使用免 cookie 的
Google Takeout。

不要把每個 `Sign in to confirm you're not a bot` 都當成 cookie 問題。先修好 EJS／Node
警告，再停止連續重試、改用乾淨的住宅 IP、降低請求頻率。上游明確警告：用已登入帳號
跑 yt-dlp 可能導致帳號暫時或永久停權。

!!! danger "Cookie 是 bearer credential"
    絕對不要顯示、貼上、截圖、commit、`chezmoi add` 或雲端備份 cookie。優先使用只登入
    YouTube 的專用 profile／帳號，而不是日常主帳號。目標檔
    `~/.config/{yth,ytmv}/cookies.txt` 已明確排除在 chezmoi 管理之外。共用 loader 會在
    yt-dlp 看到檔案之前要求 mode `0600`，並拒絕格式錯誤、過期／空白或含非 YouTube domain 的 jar，
    避免 malformed row 或 bearer value 被回顯／使用。

yt-dlp 支援的 browser 名稱包括 `brave, chrome, chromium, edge, firefox, opera,
safari, vivaldi, whale`，不包含 Arc 或 Zen：

| 瀏覽器 | 機制 | 設定 |
|---|---|---|
| **Zen**（Firefox fork） | 讀取 Firefox 格式 profile；安裝後可自動偵測。 | `from_browser = "firefox:/path/to/zen/Profiles/<profile>"` |
| **Arc** | Arc 不是支援的 browser 名稱；macOS 的 Chrome handler 又硬編碼 Chrome Safe Storage。使用隔離的 YouTube-only export。 | `cookiefile = "~/.config/yth/cookies.txt"` |
| 標準 Chrome/Firefox/… | 使用支援的名稱，最好指定專用 profile。 | `from_browser = "firefox"`（或 `chrome`…） |

### 安全的 Arc／Chromium 匯出流程

1. 開 private/incognito session 並登入 YouTube。
2. 只保留一個 tab：<https://www.youtube.com/robots.txt>。
3. 用名稱完全相符的 **Get cookies.txt LOCALLY** 擴充，只匯出 `youtube.com` cookie。
   少了「LOCALLY」的同名舊擴充曾被通報為惡意軟體。
4. 存成 `~/.config/yth/cookies.txt`，執行 `chmod 600 ~/.config/yth/cookies.txt`。
5. 關掉 private session；過期／失效後替換並刪除舊檔。

不要用 `--cookies-from-browser` 搭配 `--cookies FILE` 匯出日常 profile；它可能把所有網站
cookie 都寫入檔案。`ytmv doctor --cookies` 可在不輸出內容的前提下檢查來源載入／解密。

macOS 上若同時出現 `find-generic-password failed` 與
`cannot decrypt v10 cookies: no key found`，可能是 Chrome 的精確 Safe Storage 項目不存在。
status 44／OSStatus `-25300` 發生在授權之前，所以不會跳出視窗；補一把新 key 也解不開舊值。
metadata-only 診斷與安全替代方案見 [`ytmv help`](ytmv.md#cookies)。

## `tv yth` channel

`tv yth`（或直接 `yth`）對 `yth list --tsv` 開一個 fuzzy picker。Television 的 source 是
single-shot、看不到即時查詢，所以 channel 只 fuzzy 過濾 **標題/頻道的 display 字串**——
**字幕/描述搜尋留在 `yth search --subs`**。

| 按鍵 | 動作 |
|---|---|
| `Enter` / `Ctrl+O` / `Alt+B` | 用瀏覽器開啟影片 |
| `Ctrl+Y` | 複製影片 URL |
| `Alt+P` | 播放（有 mpv 用 mpv，否則瀏覽器） |
| `Alt+S` | 為此影片抓字幕，然後顯示詳情 |
| `Alt+J` | 傾印影片的 JSON 詳情 |

新動作用 `Alt+`（不是 `Ctrl+`），因為本 repo 的 tmux prefix 是 `Ctrl+b`——`ctrl-b` 綁定會在
傳到 tv 前就被吃掉。`o/b/y/p/s/j` 助記鍵是未來 `yth tui` 的 SSOT。

## 設定 — `~/.config/yth/config.toml`

```toml
# cookiefile   = "~/.config/yth/cookies.txt"                    # 隔離的 YouTube-only 匯出；chmod 600
# from_browser = "firefox:/…/zen/Profiles/xxxx.Default"        # 專用 Firefox/Zen profile
langs        = ["en", "en-US"]                                 # 要抓的字幕語言
open_target  = "browser"                                       # browser | mpv
```

## 儲存 (Storage)

透過 `platformdirs` 解析（會遵守 `XDG_*`）：DB 在 `~/.local/share/yth/history.db`，設定在
`~/.config/yth/config.toml`，cache 在 `~/.cache/yth/`。設 `$YTH_DB` 可覆寫 DB 路徑（測試用）。
Schema：`videos`（+ `videos_fts`）、`watch_events`（每次觀看一列；統計走 `video_stats` view）、
`subtitles`（+ `subtitles_fts`）、`meta`。FTS 是 external-content 加 trigger，所以
`enrich`/`fetch-subs` 的 UPDATE 會自動重建索引。

## 跨檔不變量 (Cross-file invariants)

動到 `yth` 就要同步維護這些（見 `CLAUDE.md` 跨檔表格那一列）：

1. `dot_dotfiles/bin/executable_yth` — launcher（PEP723 依賴 + dict-dispatch）。共用 helper 在
   `scripts/yth/__init__.py`；各子指令在 `scripts/yth/*.py`。
2. `dot_config/television/cable/yth.toml` — `o/b/y/p/s/j` 助記鍵鏡射未來的 `yth tui`；新動作用
   `Alt+`。
3. `dot_config/zsh/tools/53_yth_completion.zsh` + `dot_config/bash/53_yth_completion.bash` —
   兩份保持同步（Strategy B）。
4. `yt-dlp[default]` 必須在本 launcher PEP723、ytmv PEP723 與 `python_uv_tools` 三處一致；
   `yt-dlp-ejs` 加上 `yt_dlp_runtime_opts()`／Node 是同一份 runtime contract。
5. Docs：本頁（+ `yth.md`）、`docs/shells/aliases.md`、`docs/zsh/zsh-completions.md` §F、
   `docs/this_repo/tool-managers.md` A–Z + uv 清單、`mkdocs.yml` nav、
   `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`。

## 疑難排解 (Troubleshooting)

- **`enrich`/`fetch-subs`/`sync` 出現 `Sign in to confirm you're not a bot`** — 視為暫時性
  （不 stamp）。先修 EJS／Node 警告、停止連續重試、離開 datacenter／VPN／proxy 出口並降低
  頻率。`sync` 本質上需要 cookie；公開 `enrich`／`fetch-subs` 則只把有帳號風險的 cookie
  當最後手段，不是第一個修法。
- **`no captions`** — 影片在設定的 `langs` 裡確實沒有字幕。加語言（`--langs
  en,en-orig,zh-Hant`）或接受它（該影片會被 stamp 不再重試；`--force` 可重試）。
- **`yth sync: no cookie source configured`** — 在你設定 `cookiefile` 或 `from_browser` 前是
  預期行為。完整歷史優先用 `yth import-takeout`（免 cookie）。
- **`tv yth` 是空的** — 還沒匯入任何歷史。執行 `yth import-takeout` 或 `yth sync`。
