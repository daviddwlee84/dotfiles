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

## Cookie（僅 `sync` + 受限影片）

**公開影片不需要 cookie**——`enrich` 與 `fetch-subs` 對公開內容免驗證即可。只有 `yth sync`
（你帳號私有的歷史）以及 members-only / 年齡限制 / 私人影片才需要 cookie。

yt-dlp 的 `--cookies-from-browser` 認得 `brave, chrome, chromium, edge, firefox, opera,
safari, vivaldi, whale`——**沒有** `arc` 或 `zen`（兩者都是 fork）。這樣處理：

| 瀏覽器 | 機制 | 設定 |
|---|---|---|
| **Zen**（Firefox fork） | yt-dlp 從指定 profile 路徑讀 Firefox 格式的 `cookies.sqlite`。若有裝 Zen 會自動偵測。 | `from_browser = "firefox:/path/to/zen/Profiles/<profile>"` |
| **Arc**（Chromium fork） | `chrome` keyword 推導出的 Keychain 服務名是 *"Chrome Safe Storage"*；Arc 的是 *"Arc Safe Storage"* 且沒有 flag 可覆寫，所以 keyword 方式在 macOS 上無法解密 Arc cookie。改用匯出的 `cookies.txt`。 | `cookiefile = "~/.config/yth/cookies.txt"` |
| 標準 Chrome/Firefox/… | 直接用 keyword。 | `from_browser = "firefox"`（或 `chrome`…） |

匯出 Arc cookie：安裝 **"Get cookies.txt LOCALLY"** 擴充（Arc 是 Chromium，Chrome Web Store
擴充可裝），登入 `youtube.com`，Export → 存成 `~/.config/yth/cookies.txt`。這些會過期，需定期
重新匯出。

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
# cookiefile   = "~/.config/yth/cookies.txt"                    # Arc / 任何瀏覽器（匯出）
# from_browser = "firefox:/…/zen/Profiles/xxxx.Default"        # Zen（未設定則自動偵測）
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
4. `dot_ansible/roles/python_uv_tools/defaults/main.yml` — `yt-dlp` 條目（與 launcher PEP723
   區塊雙重宣告）。
5. Docs：本頁（+ `yth.md`）、`docs/shells/aliases.md`、`docs/zsh/zsh-completions.md` §F、
   `docs/this_repo/tool-managers.md` A–Z + uv 清單、`mkdocs.yml` nav、
   `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`。

## 疑難排解 (Troubleshooting)

- **`enrich`/`fetch-subs`/`sync` 出現 `Sign in to confirm you're not a bot`** — YouTube 的
  bot-check，datacenter IP 常見。被視為暫時性（不 stamp），下次會重試。設定 cookie
  （enrich/fetch-subs 用 `--cookies`）或改從住宅 IP 執行。
- **`no captions`** — 影片在設定的 `langs` 裡確實沒有字幕。加語言（`--langs
  en,en-orig,zh-Hant`）或接受它（該影片會被 stamp 不再重試；`--force` 可重試）。
- **`yth sync: no cookie source configured`** — 在你設定 `cookiefile` 或 `from_browser` 前是
  預期行為。完整歷史優先用 `yth import-takeout`（免 cookie）。
- **`tv yth` 是空的** — 還沒匯入任何歷史。執行 `yth import-takeout` 或 `yth sync`。
