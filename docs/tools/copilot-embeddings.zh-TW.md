# Copilot embeddings → 語意搜尋

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[Copilot → Claude Code proxy](copilot-claude-proxy.zh-TW.md)（`copilot-api`,
`localhost:4141`）是 OpenAI 相容 (compatible) 的代理 (proxy)，同時提供
**`POST /v1/embeddings`**，由同一個 GitHub Copilot 訂閱支撐。Copilot 開放三個
**1536 維** embedding 模型：`text-embedding-3-small`（預設）、
`text-embedding-ada-002`、`text-embedding-3-small-inference`。這讓 proxy 直接變成一個
零額外成本的**本機語意搜尋 (semantic search)**後端。

- **Shell helper**：`~/.config/shell/44_copilot_embed.sh`（`copilot-embed`、`semsearch`）
- **搜尋引擎**：`scripts/semsearch.py`（用 `uv run --script` 執行，透過
  `chezmoi source-path` 解析 —— 留在 chezmoi source tree，不會被 apply 到 `$HOME`）
- **模型 pin（SSOT）**：`~/.config/shell/04_ai_agents.sh` 裡的 `AICAP_EMBED_MODEL`
- 需要 proxy 在跑（`copilot-proxy start`）；兩個 helper 都會自動幫你起。

!!! warning "與 proxy 相同的 Copilot ToS 風險"
    embeddings 一樣走這個逆向工程的 proxy 與 Copilot 訂閱 —— 參見
    [proxy 文件的 ToS 警告](copilot-claude-proxy.zh-TW.md)。索引大型語料會打出大量
    請求，而且這個 fork **沒有 rate limiter**；索引大目錄請刻意為之。

## 快速開始

```sh
copilot-embed "hello world" | jq 'length'     # → 1536（原始 embedding 向量）

semsearch index                                # 索引預設語料（chezmoi docs/tools）
semsearch "how do I switch the copilot model"  # 自然語言搜尋 → 依相關度排序
semsearch "trim a video clip" -k 5             # top-5
semsearch index ~/notes                        # 索引另一個目錄
semsearch "quarterly goals" --corpus ~/notes   # 查那個語料
```

## 運作方式

```
text ──▶ copilot-embed / semsearch.py ──POST /v1/embeddings──▶ copilot-api (localhost:4141)
                                                                 │ Authorization: Bearer <copilot token>
                                                                 ▼
                                                          api.githubcopilot.com  (你的 Copilot 訂閱)
```

`semsearch` 以空行分段把檔案切塊（記住每塊的起始行號）、分批 embed、快取 (cache) 向量，再用
cosine 相似度對你的查詢向量排序。排序看的是**語意 (semantic)** 而非關鍵字 —— 例如
`"trim a video clip"` 會撈出 `ffmpeg.md` 的 *"Trim / cut"* 段落，即使用字不同。

!!! danger "embeddings 的 `input` 必須是陣列（issue #100）"
    proxy 對**純字串** `input` 會回一個籠統的 `400 Bad Request` —— 這就是 fork 的
    [issue #100](https://github.com/caozhiyuan/copilot-api/issues/100)
    （「Can not call /v1/embeddings successful」）。解法很單純：送
    `"input": ["你的文字"]`（陣列）。`{"input":"你的文字"}` 會 400，
    `{"input":["你的文字"]}` 才回向量。兩個 helper 一律送陣列（`copilot-embed`
    包一段文字；`semsearch.py` 每次請求批次最多 64 段）。

## Shell helper

### `copilot-embed [--model M] [--json] [TEXT | -]`

把 `TEXT`（位置參數）或 **stdin**（`-` 或 pipe）做 embedding，把向量以 JSON 陣列印到
**stdout**（狀態／metadata 走 **stderr**，所以 pipe 很乾淨）。

```sh
copilot-embed "some text"           # 向量（JSON 陣列）
printf 'doc body' | copilot-embed   # 從 stdin embed
copilot-embed --json "hi" | jq '.usage'   # 完整 API 回應（usage、index…）
copilot-embed --model text-embedding-ada-002 "text"   # 換模型
copilot-embed -l                    # 列出 proxy 提供的 embedding 模型 id
```

| Flag / env | 預設 | 意義 |
|---|---|---|
| `--model M` / `AICAP_EMBED_MODEL` | `text-embedding-3-small` | embedding 模型（空值 → 用端點預設） |
| `--json` | off | 印完整回應而非只有向量 |
| `-l` / `--list` | — | 從 `/v1/models` 列出 embedding 模型 |

proxy 沒回應時會自動幫你起（跟 `copilot-run` 一樣）。需要 `curl` + `jq`。

### `semsearch index [PATH...]` / `semsearch <QUERY> [-k N] [--corpus PATH]`

`scripts/semsearch.py` 的薄封裝（透過 `chezmoi source-path` 解析、per-shell 快取 ——
跟 `aiblock` 同套路）。會自動起 proxy，再用 `uv` 跑引擎。

- **`index [PATH...]`** —— 走訪每個 `PATH` 抓 `*.md,*.txt,*.sh,*.py`（用
  `--glob '*.md,*.py'` 覆寫）、切塊、批次 embed、快取。未給 `PATH` 時預設 =
  `<chezmoi source>/docs/tools`。**增量 (incremental)**：只有內容 hash 是新的塊才會重新 embed；
  沒變的塊沿用、刪除／變動的塊會被清掉。`--rebuild` 強制整包重 embed。
- **`<QUERY>`** —— 對查詢做 embedding，印出 top-`k`（預設 8）塊，格式為
  `score  path:start_line` 加一行摘要，最相關在前。`--corpus PATH` 選要搜尋哪個已索引
  語料（預設：docs 語料）。

每個語料以其 root 路徑的 hash 為 key，不同目錄樹不會互撞。快取位置：

```
$XDG_STATE_HOME/copilot-proxy/embeddings/<corpus-hash>.jsonl   # (預設 ~/.local/state/…)
```

每塊一行 JSON（`{path, start_line, hash, text, embedding}`）—— 可直接檢視、方便清理。
（向量以 JSON 浮點數存，所以快取偏大：約 20 KB/塊。docs 大小的語料沒問題；刪掉某個
`<hash>.jsonl` 即可重設該語料。）

## 設定

| Env var | 預設 | 意義 |
|---|---|---|
| `AICAP_EMBED_MODEL` | `text-embedding-3-small` | embedding 模型（SSOT 在 `04_ai_agents.sh`；空值 → 端點預設） |
| `COPILOT_EMBED_BASE` | `http://localhost:$COPILOT_PROXY_PORT` | proxy base URL（由 `semsearch` wrapper 設定） |
| `COPILOT_PROXY_PORT` | `4141` | proxy port（與 `43_copilot_proxy.sh` 共用） |
| `XDG_STATE_HOME` | `~/.local/state` | embedding 快取位置 |

## 驗證

```sh
echo "hello world" | copilot-embed | jq 'length'    # → 1536
copilot-embed -l                                     # → 三個 embedding 模型
semsearch index && semsearch "how do I switch the copilot model"
#   → copilot-claude-proxy.md 排在最前
semsearch index                                      # 再跑一次 → 「0 new」（增量快取命中）
```

## 延伸閱讀

- [Copilot → Claude Code proxy](copilot-claude-proxy.zh-TW.md) —— 提供
  `/v1/embeddings` 的 proxy（認證、模型、ToS、地雷）
- [aicapture](aicapture.zh-TW.md) —— 兄弟 AI shell 工具（`aifix`、`air`、`http`
  agent），`copilot-embed` 沿用其 curl+jq 模式
- [caozhiyuan/copilot-api#100](https://github.com/caozhiyuan/copilot-api/issues/100)
  —— 本文解掉的 array-`input` 地雷
