# 在終端機中以 Markdown 閱讀網頁

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

聚焦模式 (focus mode) 閱讀（類似 Safari Reader / Firefox Reader View），
但由終端機驅動：抓一個頁面、剝出文章主體、在 pager 中以 markdown 呈現。
適合離線閱讀、把內容餵給 LLM，或單純不想離開 shell 卻又懶得看瀏覽器框架時。

這個 repo 提供四個可互換的網頁讀取器 (web reader)，分別覆蓋
**遠端 (remote) 對本地 (local)**、**文章抽取對全頁**，以及 **不同抽取器策略** 的常見組合。
依當下要讀的頁面挑選合用的那個。

## TL;DR

| 命令 | Extractor | 本地 / 遠端 | 最適場景 |
|---------|-----------|----------------|----------|
| `readurl <url>` | [Jina AI Reader](https://jina.ai/reader) (`r.jina.ai`) | 遠端 | 預設選項。任何頁面，本地除了 `glow` 不需任何依賴。快速。 |
| `readlocal <url>` | [trafilatura](https://trafilatura.readthedocs.io/) | 本地（Python） | 隱私敏感或離線場景。對新聞/部落格類文章調得很好。 |
| `readnode <url>` | [readability-cli](https://gitlab.com/gardenappl/readability-cli)（Mozilla Readability port） | 本地（Node） | 與 Firefox/Safari Reader View 同樣的演算法。文章還原度通常最佳。 |
| `readraw <url>` | `curl \| pandoc -f html -t gfm` | 本地 | 逃生口：當文章抽取剝太多時用，例如 docs / reference 頁面。 |

四個工具都把結果 pipe 給 [`glow`](https://github.com/charmbracelet/glow) 渲染與分頁，
而且都把 fetch 包在 `try_direct_then_proxy` 裡，所以不需 proxy 就能連的頁面零開銷。

來源：`dot_config/zsh/tools/55_web_reader.zsh`（讀取器）以及 `dot_config/zsh/tools/50_networking.zsh`（proxy helpers）。

## 全景 — 為什麼是四個工具，而不是一個

「把網頁讀成 markdown」可拆成三個獨立選擇：

1. **Fetch** — `curl`、headless 瀏覽器（給 JS 重的頁面用）、或代你抓取的遠端服務。
2. **Extract** — 拿掉導覽列、廣告、留言、頁尾，只留文章；或不抽取，要全頁也行。
3. **Render** — 在終端機渲染 markdown；`glow`、`mdcat`，或單純 stdout。

沒有單一工具能把整條 pipeline 都做好：

- [**Jina AI Reader**](https://jina.ai/reader) 把 fetch + extract 收成一個 HTTP GET：
  `https://r.jina.ai/<url>` 直接回讀好的 markdown。零安裝。代價：是遠端服務（隱私／可用性），
  且本身可能在某些網路被擋 — 那種情況下會 fallback 走 proxy。
- [**trafilatura**](https://trafilatura.readthedocs.io/) 是 Python library + CLI，主打文章抽取。
  本地、離線，新聞／部落格語料上久經實戰。弱點：內建 fetcher 很素 — 反爬蟲嚴格的網站可能踩雷。
- [**readability-cli**](https://gitlab.com/gardenappl/readability-cli)（binary：`readable`）
  包裝 Mozilla 的 Readability library — 也就是 Firefox / Safari Reader View 背後的演算法。
  對文章型頁面還原度極佳。
- [**pandoc**](https://pandoc.org/) 不做任何抽取；它把整段 HTML 轉成 GFM markdown。
  當「文章主體」就是整頁時很方便（例如 man-page 風的規格、GitHub README 的渲染 HTML、單欄文件頁）。

其它有考慮但沒接進來的選項（要的話自己手動裝）：

- [**monolith**](https://github.com/Y2Z/monolith) — 把整個頁面（含資源）存成單一 HTML 檔。
  適合存檔，但對聚焦閱讀沒幫助。
- [**w3m / lynx / elinks -dump**](https://w3m.sourceforge.net/) — 文字模式瀏覽器，渲染為純文字（不是 markdown）。
  其它都失敗時的逃生口；不做抽取。
- [**Postlight Parser**](https://github.com/postlight/parser) — 比 readability-cli 老、維護較少，同家族。
- [**single-file-cli**](https://github.com/gildas-lormeau/single-file-cli) — 基於 headless Chrome；
  做閱讀過頭了，做存檔很不錯。
- [**mdcat**](https://github.com/swsnr/mdcat) — 另一個 markdown 渲染器（支援超連結終端機）；
  這裡仍以 `glow -p` 為預設，因為它會分頁。

## 用法

```bash
# jina.ai Reader — 預設、零安裝（除了 glow）
readurl nytimes.com/2024/.../some-article

# trafilatura — 全本地，不依賴第三方
readlocal example.com/some-article

# Mozilla Readability — 文章還原度最佳
readnode example.com/some-article

# 不抽取 — 整頁 HTML → GFM markdown
readraw docs.example.com/reference/api
```

URL 不需要 scheme — `_norm_url` 會在缺少時補上 `https://`。

### Recipes

**將抽取的 markdown 存成檔案**

```bash
trafilatura -u "https://example.com/post" --markdown > post.md
readable "https://example.com/post" > post.md
curl -fsSL https://r.jina.ai/https://example.com/post > post.md
```

**Pipe 到 chat / LLM CLI**

```bash
trafilatura -u "$url" --markdown | llm -s "Summarize in 5 bullets"
readable "$url" | claude -p "Extract the key claims"
```

**在終端機帶顏色但不分頁渲染（用在 pipe 裡很方便）**

```bash
readurl example.com | cat      # glow 仍會 format；cat 拿掉 pager
```

## Proxy 行為

每個讀取器都把 fetch 包在 `try_direct_then_proxy`（出自 `50_networking.zsh`）。意思是：

1. 第一次嘗試直連 — 不過 proxy、不動 env。便宜。
2. 失敗（非零 exit code），且偵測到本地 proxy 時，才透過 `withproxy` 重試。
3. 沒有可用 proxy 時，保留原始 exit code。

當重試發生時 stderr 會出現一則訊息：`[retry via proxy http://127.0.0.1:7890]`。

### 偵測優先序

1. 已 export 的 `$LOCAL_PROXY_URL`（例如 `http://127.0.0.1:7890`）。
2. 否則，若 `~/.config/clash/config.yaml` 或 `~/Library/Application Support/clash/config.yaml`
   存在可用的 Clash 設定，從中讀取可達的 `mixed-port:` 或 `port:`/`socks-port:`。
3. 否則，依序自動探測 loopback port：`7890 7891 1087 8118 8080`。第一個 TCP-accepting port 勝出。
4. 否則，標記為 proxy 不可用。

結果以 `_ZSH_NET_PROXY_CACHE` 在每個 shell 內快取 (cache)。`proxy-off` 與 `proxy-refresh`
會在下次查詢前清除快取。啟動或關閉本地 proxy 後，呼叫 `proxy-refresh` 強制立即重新探測。

### 拆分 HTTP / SOCKS5 port（Clash `port:` + `socks-port:`）

Clash 的 mixed-port 設定（`mixed-port: 7890`）在同一個 port 同時提供 HTTP 與 SOCKS5 —
這裡的預設行為直接可用，且 helper 會在有 Clash 啟用設定時優先取那個 port。

如果你的設定把它們拆開（例如 `port: 7890` 走 HTTP、`socks-port: 7891` 走 SOCKS5），
請兩個都明確設定：

```bash
export LOCAL_PROXY_URL="http://127.0.0.1:7890"           # HTTP/HTTPS
export LOCAL_PROXY_SOCKS_URL="socks5://127.0.0.1:7891"   # SOCKS5
```

這個 repo 也預先建立了一個 create-only 的本機獨有 stub `~/.config/zsh/99_local_proxy.zsh`。
若想要永久性的本機覆寫又不想之後在 chezmoi 中產生 diff，把那個檔案裡的區塊取消註解並調整即可。

接著 `withproxy` 與 `proxy-on` 會 export：

| Env var | 讀取自 |
|---|---|
| `http_proxy`、`https_proxy`、`HTTP_PROXY`、`HTTPS_PROXY` | `LOCAL_PROXY_URL` |
| `ALL_PROXY`、`all_proxy` | `LOCAL_PROXY_SOCKS_URL`（fallback：`LOCAL_PROXY_URL`） |

當兩者不同時，`proxy-status` 會把兩個 URL 都顯示出來。

### 啟動 shell 時自動啟用

對總是要走本地 proxy 的機器，可在 shell 啟動時自動 export 環境變數：

```bash
# 例如放在 ~/.config/zsh/99_local_proxy.zsh、其它本機獨有的 zsh 檔，或 ~/.zshenv
export LOCAL_PROXY_AUTO_ACTIVATE=1
```

當 `50_networking.zsh` 被 source 時，若偵測到 proxy 就會靜默執行 `proxy-on -q`。
沒有 proxy 在跑的機器則什麼都不會發生。

可與 `LOCAL_PROXY_URL` + `LOCAL_PROXY_SOCKS_URL` 搭配以獲得確定性行為，
或單獨使用、依賴自動 port 探測。

## Proxy helper 速查表

| Helper | 範圍 | 備註 |
|---|---|---|
| `withproxy <cmd…>` | 單個子行程 | `withproxy curl …`、`withproxy pip install …` |
| `try_direct_then_proxy <cmd…>` | 單個子行程，直連 → proxy fallback | 讀取器內部用的就是這個 |
| `proxy-on` / `proxy-on -q` | 當前 shell，export 環境變數 | `-q` 略過成功訊息 |
| `proxy-off` | 當前 shell，unset 環境變數 | 也會清掉 `ALL_PROXY`/`all_proxy`/`NO_PROXY` |
| `proxy-status` | 唯讀 | 顯示 **active** / **available** / **unavailable** + HTTP / SOCKS URL |
| `proxy-test [url]` | 單個子行程 | 用 `curl` 驗證出網；預設打 Google `generate_204` endpoint，因為 `ping` 不會使用 proxy 環境變數 |
| `proxy-refresh` | 清快取，重新探測 | 啟動或關閉 proxy 後執行 |

## 安裝

| 工具 | macOS | Debian/Ubuntu | 透過 ansible |
|---|---|---|---|
| `glow` | `brew install glow` | GitHub binary | `devtools` role |
| `pandoc` | `brew install pandoc` | `apt install pandoc` | `devtools` role |
| `trafilatura` | `uv tool install trafilatura` | `uv tool install trafilatura` | `python_uv_tools` role（透過 `chezmoi init --force` 啟用） |
| `readable` (readability-cli) | `npm install -g readability-cli` | `npm install -g readability-cli` | `js_cli_tools` role（透過 `installJsCliTools=true` 啟用，預設開啟） |
| `curl`、`nc` | 內建 | 內建 | — |

每個讀取器在呼叫時會檢查依賴，若缺項就印一行安裝提示，
所以全新機器上跑 `readnode` 會直接告訴你該執行什麼指令。

## 相關

- `docs/shells/aliases.md` — 所有 shell 捷徑的單行參考表。
- `docs/tools/networking.md` — 更廣泛的網路 (networking) CLI 文件（nmap、doggo、bandwhich 等）。
- `dot_config/zsh/tools/50_networking.zsh` — proxy helper 實作。
- `dot_config/zsh/tools/55_web_reader.zsh` — 讀取器函式 (function) 實作。
