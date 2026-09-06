# Raycast AI 自帶模型 (BYOK) → 本機 Copilot 代理 (proxy)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

Raycast AI 可以吃**你自己的**模型後端，但真正能吃的入口只有一個：Settings → AI →
Experiments → **Custom Providers**。它讀 `~/.config/raycast/ai/providers.yaml`，而且
**請求是從你的 Mac 直接送出**，所以 `http://localhost` 的 `base_url` 真的連得到。把它
指向 [Copilot → Claude Code 代理 (proxy)](copilot-claude-proxy.zh-TW.md)（`copilot-api`），
Copilot 訂閱裡每個模型就變成 Quick AI / AI Chat / AI Commands 的一等公民。
**這不需要 Raycast Pro**（在非 Pro 的試用帳號上實測通過）。

- **Shell helper**：`~/.config/shell/45_copilot_raycast.sh`（`copilot-raycast`）
- **產生的檔案**：`~/.config/raycast/ai/providers.yaml`（Raycast 監看的那份；
  `COPILOT_RAYCAST_CONFIG` 可覆寫）
- **`base_url` 來源（SSOT）**：`43_copilot_proxy.sh` 的 `_copilot_pinned_base` ——
  throttle shim 開著時是 `:4142`，否則是 `:4141`
- **備份**：`~/.local/state/copilot-raycast/backups/`（保留最近
  `COPILOT_RAYCAST_KEEP`=10 份）
- 需要 proxy 在跑：`generate` / `diff` / `probe` 沒回應時會自動 `copilot-proxy start`；
  `status` 與 `doctor` **不會**（它們是唯讀診斷，只回報「沒在跑」）。
- 需要 `curl` + `jq`；`yq` 用於驗證與保留檔案裡其他 provider。

!!! warning "與 proxy 相同的 Copilot ToS 風險"
    Raycast 的請求一樣走那個逆向工程 (reverse-engineered) 的 proxy 與你的 Copilot
    訂閱 —— 參見 [proxy 文件的 ToS 警告](copilot-claude-proxy.zh-TW.md)。而且這裡多了
    一個新的量體來源：Quick AI 很容易在幾秒內連續打好幾發，跟 Claude Code 共用同一個
    後端。這正是把 `base_url` 指向 throttle shim 的原因（見下）。

## 快速開始

```sh
copilot-raycast doctor            # 前置檢查：proxy、shim、Raycast、設定檔、drift
copilot-raycast generate          # 探針掃描 → 備份 → 驗證 → 原子性 (atomic) 寫入
copilot-raycast                   # status（預設動作，唯讀）
copilot-raycast probe             # 每個 chat model 的分類表（零額度）
copilot-raycast diff              # generate 會改動什麼
```

寫完約 5 秒內，在 Raycast 的模型選單打 `copilot` 就會看到全部 —— 後綴由
`COPILOT_RAYCAST_SUFFIX`（預設 `" (Copilot)"`）決定，就是為了讓一個關鍵字撈到整組。

## 為什麼「Custom API Keys」那個框不能用

這是每個人第一個會去點、也一定會撞牆的地方。Settings → AI 裡有兩個看起來都很像
「自帶模型」的入口，但只有一個能連到本機：

| Raycast 的入口 | 請求路由 | 能指定 endpoint 嗎 | 對本機 proxy |
|---|---|---|---|
| Settings → AI → **Custom API Keys**（BYOK） | 「requests are processed through our servers」 | **不能** —— 只有一個 key 欄位 | **不可用** |
| Settings → AI → Experiments → **Custom Providers** | 「routed directly to the provider's servers」 | **能** —— `base_url` | **可用** |

BYOK 那個框只認**固定的供應商清單**，而且你交的是**金鑰**而不是**位址**。
Raycast 1.104 面板上的原話是
`Anthropic, Google, OpenAI: Requests are routed via Raycast servers` /
`OpenRouter: Requests are routed directly to the provider's servers`，而官方 manual
的說法是 requests are "processed through our servers"（用來統一 API、做 fallback 與
最終的 prompt 管理）。從 Raycast 的機房出發，`http://localhost:4141` 當然是打不到你的
Mac 的 —— 而唯一直連的那一項（OpenRouter）也一樣只有金鑰欄位、沒有 endpoint 欄位。
**不管把 key 填成什麼，這條路都不會通。**

## 正確的入口：Experiments → Custom Providers

1. Raycast → Settings → AI → **Experiments** → 打開 **Custom Providers**。
2. 回到 Custom Providers → **Reveal Providers Config** —— 它會開到
   `~/.config/raycast/ai/providers.yaml`。第一次打開這個實驗功能時，Raycast 會從自己的
   bundle 把 `providers.template.yaml` 釋出到同一個目錄（這也是 `doctor` 用來判斷實驗
   功能開過沒的觀測點；這個 toggle 本身沒有公開 API）。
3. `copilot-raycast generate` 產生真正的 `providers.yaml`，Raycast 約 5 秒內重新載入。

Raycast 對這條路徑的說明是請求 "routed directly to the provider's servers" ——
也就是從你的 Mac 出發，所以 `localhost` 成立。

!!! note "官方有寫，但寫得很少 —— 而且分散在兩個不同的地方"
    per-user 的那份檔案**確實**寫在官方 manual 裡，位置是
    [AI → Custom Providers (Bring Your Own Models)](https://manual.raycast.com/v1/ai#custom-providers-bring-your-own-models)
    —— 這個 URL 就是 app 裡 **Learn more about custom providers** 按鈕開的那一頁。
    但它只寫到「Settings → AI → Custom Providers → Reveal Providers Config」加一份
    可下載的 template，欄位一個都沒列，所以下面那張 schema 表是從 template 與實測行為
    讀出來的，不是從那一頁抄的。另一頁
    [teams/custom-provider](https://manual.raycast.com/teams/custom-provider.md)
    講的是**另一個功能**：組織層級的 `providers.yaml`，會
    "overrides any local provider files set by members"，標著
    *Tier: Enterprise Exclusive*。兩者用的是同一份 schema。

    Enterprise 與 Pro 都不需要。本文的 9 個模型就是在一個非 Pro 的試用帳號上跑起來的：
    `defaults read com.raycast.macos subscriptions_active` 是 `0`、
    `raycastAI_deviceInfo` 解出來是 `{"credits":48,"total_credits":50}`、
    每個載入的模型都帶 `"requires_better_ai": false`。

## 運作方式

```
Raycast (Quick AI / AI Chat / AI Commands)
  │ 讀 ~/.config/raycast/ai/providers.yaml（啟動時 + 檔案變更後 ~5s）
  │ POST <base_url>/chat/completions        ← 從你的 Mac 直接送出，不經 Raycast 伺服器
  ▼
copilot-throttle-shim (localhost:4142)      ← 併發上限 4 + 403/429 透明重試
  │
  ▼
copilot-api (localhost:4141)                ← Claude Code 也走這條
  │ Authorization: Bearer <copilot token>
  ▼
api.githubcopilot.com                       （你的 Copilot 訂閱）
```

Raycast 會自己在 `base_url` 後面接 `/chat/completions`。copilot-api 兩個路徑都服務
（`/chat/completions` 與 `/v1/chat/completions`），所以 `http://localhost:4142` 與
`http://localhost:4142/v1` 都能通；產生器寫的是後者。

Raycast 在**載入設定時不打任何網路請求** —— 它只解析 YAML。所以一個根本用不了的 model
id 在選單裡看起來完全正常，直到你送出第一則訊息才 400。這就是下一節那個探針不是可有可無
的原因。

## 該指向 :4142 還是 :4141

寫進 `providers.yaml` 的 `base_url` 沿用 `_copilot_pinned_base`：throttle shim 開著時
指向 shim（`:4142`），否則直接指 fork（`:4141`）。跟 `copilot-here` 的持久化 pin 同一套
理由 —— 這個檔案的壽命比當下這個 shell 長，所以**不能**用「shim 現在活著嗎」當條件。

這裡比任何地方都更需要 shim：Raycast 與 Claude Code 現在共用同一個 Copilot 後端，而
Quick AI 的使用型態就是突發 (burst) —— 一連串短請求塞進 Claude Code 正在跑的長 session
中間。shim 的 semaphore（併發 4）加上 403/429 的透明重試，正是為了不讓這種爆量把
Claude Code 打成 `Please run /login`。沒開的話：

```sh
copilot-proxy shim on             # 之後 copilot-raycast generate 重寫 base_url
```

反過來，**探針掃描刻意直接打 `:4141`**：那是 ~22 個請求 6 條並發，走 shim 只會被它的
4 張通行證排隊，而且探針在驗證階段就被拒了，根本到不了 shim 的重試邏輯保護的位置。要
連掃描也節流的話設 `COPILOT_RAYCAST_PROBE_BASE`。

## 零額度探針 (zero-quota probe)

這是這份文件最有價值的一段。**`/v1/models` 不能拿來當過濾條件**，只能拿來當
metadata 來源；能不能用，只有問了才知道。

作法：對 `/chat/completions` POST 一個 `{"model":"<ID>","messages":[]}`。這個請求在
**request 驗證階段**就被打回，**還沒進到推論 (inference)**，所以不動任何用量計數器。
回傳的錯誤內文剛好把所有模型分成三類：

| 回應內文 | 判定 | 動作 |
|---|---|---|
| `messages must be non-empty` | **可用** —— `/chat/completions` 走得通 | **寫進** `providers.yaml` |
| `model_not_supported` | 目錄有列，但這個帳號沒有權限 | 丟掉 |
| `unsupported_api_for_model` | 模型存在，但只在 `/responses` 上 | 丟掉 |

三種回應的實際樣子（copilot-api 會把上游的錯誤原封不動包在 `error.message` 裡，所以
是雙層 JSON）：

```
$ curl -s -X POST http://localhost:4141/v1/chat/completions \
    -H 'content-type: application/json' -d '{"model":"claude-opus-5","messages":[]}'
{"error":{"message":"{\"error\":{\"message\":\"messages must be non-empty\",\"code\":\"\"}}\n","type":"error"}}

$ ... -d '{"model":"claude-sonnet-4-5","messages":[]}'
{"error":{"message":"{\"error\":{\"message\":\"The requested model is not supported.\",\"code\":\"model_not_supported\",\"param\":\"model\",\"type\":\"invalid_request_error\"}}\n","type":"error"}}

$ ... -d '{"model":"gpt-5.5","messages":[]}'
{"error":{"message":"{\"error\":{\"message\":\"model \\\"gpt-5.5\\\" is not accessible via the /chat/completions endpoint\",\"code\":\"unsupported_api_for_model\"}}\n","type":"error"}}
```

!!! danger "`/v1/models` 的靜態 metadata 兩個方向都會騙人"
    **會漏掉能用的**：`gemini-2.5-pro` 與 `gemini-3-flash-preview` 的
    `supported_endpoints` 是 **`null`**（空的），照 metadata 過濾會被直接砍掉 ——
    但它們**都能用**。

    **會留下不能用的**：`claude-sonnet-4-5`（以及 `claude-opus-4-6/4-7/4-8`、
    `claude-sonnet-4-6`、`claude-haiku-4-5`）同時具備 `supported_endpoints` 含
    `"/chat/completions"`、`model_picker_enabled: true`、`policy.state: "enabled"`，
    看起來完美無缺 —— **每一個都回 `model_not_supported`**。

    ```sh
    curl -s http://localhost:4141/v1/models \
      | jq -r '.data[] | select(.id=="claude-sonnet-4-5" or .id=="gemini-2.5-pro")
               | {id, model_picker_enabled, policy: .policy.state, endpoints: .supported_endpoints}'
    #   claude-sonnet-4-5  true  "enabled"  ["/chat/completions","/v1/messages"]   → 其實不能用
    #   gemini-2.5-pro     true  "enabled"  null                                   → 其實能用
    ```

    `/v1/models` 裡**沒有任何欄位**能預測這件事。探針是唯一的真相來源。

掃描前只有兩個靜態預過濾：`capabilities.type == "chat"`（濾掉三個 embedding 模型）與
把 `[1m]` 別名 grep 掉（那是只給 Claude Code 看的 1M context 語法糖，原生 API client
送過去會被拒）。其餘一律交給探針。

**temperature 沒辦法用同一招探。** messages 的檢查排在參數驗證**之前**，所以
`{"messages":[],"temperature":0.7}` 一樣只會回 `messages must be non-empty`。因此
temperature 是啟發式 (heuristic) 而非探測結果：OpenAI 的 reasoning 家族
（`gpt-*`、`*codex*`、`o1`/`o3`/`o4*`）與 Microsoft `mai-*` 標 `false`，其餘標 `true`
（Anthropic 與 Google 在這裡都吃得下）。要整批覆寫用 `COPILOT_RAYCAST_TEMP=on|off`。

## `providers.yaml` 的結構

產生出來的檔案（節錄；完整版有 9 個模型）：

```yaml
providers:
  - id: copilot
    name: "GitHub Copilot"
    base_url: http://localhost:4142/v1
    models:
      # --- Anthropic ---
      - id: "claude-opus-5"
        name: "Claude Opus 5 (Copilot)"
        context: 1000000
        abilities:
          temperature: { supported: true }
          vision: { supported: true }
          system_message: { supported: true }
          tools: { supported: true }
          reasoning_effort: { supported: true }
```

| 欄位 | 必填 | 意義 |
|---|---|---|
| `providers[].id` | 是 | 唯一 provider id；`copilot-raycast` 只擁有 `COPILOT_RAYCAST_ID`（預設 `copilot`）這一個，其他一律原樣保留 |
| `providers[].name` | 是 | Raycast 裡顯示的供應商名稱 |
| `providers[].base_url` | 是 | Raycast 會在後面接 `/chat/completions` |
| `providers[].api_keys` | 否 | `別名 → 金鑰` 的 map。**本機 proxy 不需要**（不需要認證時可省略） |
| `providers[].additional_parameters` | 否 | 併進 `/chat/completions` body 的額外參數 |
| `models[].id` | 是 | 供應商認得的 model id，**必須是字串** |
| `models[].name` | 是 | Raycast 選單裡的顯示名稱，**必須是字串** |
| `models[].description` | 否 | 說明文字 |
| `models[].provider` | 否 | 對應到某個 `api_keys` 別名 |
| `models[].context` | 是 | context window，**必須是裸整數** —— 引號括起來或缺漏都會炸掉整份檔案 |
| `models[].abilities.*` | 否 | `temperature` / `vision` / `system_message` / `tools` / `reasoning_effort`，各自 `{ supported: bool }` |

metadata 的對應關係：`capabilities.limits.max_context_window_tokens` → `context`，
`capabilities.supports.vision` → `abilities.vision`，`.tool_calls` → `abilities.tools`，
`.reasoning_effort`（**是陣列**，非空才算有）→ `abilities.reasoning_effort`。
`system_message` 在 `/v1/models` 裡沒有對應欄位，而每個 Copilot chat model 都吃得下
system message，所以固定寫 `true`。

模型保留與 `_copilot_pick_best_model` 相同的 vendor 分組順序：Claude、Codex、GPT、
**grok**、Gemini；Claude 內部為 Fable > Opus > Sonnet > Haiku，同分時版本新的在前。
明確 vendor band 讓檔案易讀；未知 vendor 則依 catalog 的 `model_picker_category`
（`powerful > versatile > lightweight`）在 fallback band 內互相比較；所有未知 vendor
仍刻意放在已知 Gemini band 後，維持穩定的 vendor grouping。
Grok 排在 GPT 後、Gemini 前；GPT/o-series 與 grok band 內也使用同一個 catalog tier，
避免新版 lightweight id 排到舊版 powerful 之前。Grok 並刻意維持
`temperature: supported` —— grok 接受
temperature，不像 reasoning-only 的 GPT/Codex endpoints —— 最後依 `.vendor` 分組加註解。註解用的是
`/v1/models` 給的原始 vendor 字串，所以 `gpt-5.4` 會落在 `# --- OpenAI ---` 而
`gpt-5-mini` 落在 `# --- Azure OpenAI ---` —— 那真的是目錄裡寫的，純外觀問題。

## Shell helpers

### `copilot-raycast [status]` —— 預設動作，唯讀

```
copilot-raycast   config /Users/david/.config/raycast/ai/providers.yaml

  file             present, 9 model(s) under provider 'copilot'
  raycast          9 model(s) live in the picker
  base_url         http://localhost:4142/v1
  shim             on (:4142)
  live usable      9 model(s) pass the probe
  drift            none — the file matches the live catalogue
```

`file` 是檔案裡有幾個模型，`raycast` 是 Raycast **實際載入**了幾個 —— 兩者不同就代表
設定被打回了（見陷阱）。`drift` 拿檔案裡的 id 跟即時探針結果做 `comm(1)` 比對，會列出
`stale in file:` 與 `missing      :` 兩種差異。

### `copilot-raycast generate [-n|--dry-run] [-a|--all]`

探針掃描全部 chat model → 渲染 → 寫暫存檔 → `yq` 驗證 → 時間戳備份 → 一次 `mv` 就位。

```
copilot-raycast: backup /Users/david/.local/state/copilot-raycast/backups/providers-20260726-173630.yaml
copilot-raycast: wrote 9 model(s) → /Users/david/.config/raycast/ai/providers.yaml
  base_url http://localhost:4142/v1   (Raycast reloads within ~5s)
  copilot-raycast status   # confirm Raycast actually accepted it
```

- `-n` / `--dry-run` —— 渲染到 stdout，什麼都不寫。
- `-a` / `--all` —— 連被探針打回的模型也輸出，但**整段註解掉**，方便下次 GitHub 改權限
  時直接 diff：

  ```yaml
      # - id: "claude-opus-4-8"   # not_supported
      #   name: "Claude Opus 4.8 (Copilot)"
      #   context: 1000000
  ```

- **其他 provider 會原樣保留**：用 `yq` 把所有 `id != COPILOT_RAYCAST_ID` 的項目撈出來，
  重新縮排後接在 `# --- other providers, preserved from the previous file ---` 底下，
  連它們原本的註解都留著。檔案已存在**但沒有 `yq`** 時，`generate` 會**拒絕執行**而不是
  盲目覆蓋 —— 在任意 YAML 裡用 POSIX 工具分辨「provider 項目」與「model 項目」沒有便宜
  的作法。
- 一個模型都沒通過探針時也會拒絕寫入（那是權限或認證問題，不是設定問題，提示你跑
  `copilot-proxy doctor`）。

### `copilot-raycast diff`

現況檔案 vs `generate` 會寫出來的內容，unified diff。`# Probed:` 那行時間戳在**兩邊**
都會被正規化成 `<run timestamp>`，否則每次都必然有差異，這個指令就沒有意義了：

```
copilot-raycast: no changes (/Users/david/.config/raycast/ai/providers.yaml is current)
```

檔案還不存在時，改成印出「generate 會建立這份」加完整內容。

### `copilot-raycast probe [MODEL]`

不帶參數 = 全部模型的分類表；帶一個 model id = 單一判定字串（`ok` /
`not_supported` / `responses_only` / `no_response` / `unknown`），適合腳本使用。

```
copilot-raycast probe   base http://localhost:4141   22 chat model(s)

  OK             claude-opus-5                1000000 vision tools reasoning
  NOT_SUPPORTED  claude-opus-4-8              1000000 vision tools reasoning
  NOT_SUPPORTED  claude-sonnet-4-5             200000 vision tools
  RESPONSES_ONLY gpt-5.5                      1050000 vision tools reasoning
  OK             gpt-5.4                      1050000 vision tools reasoning
  OK             gemini-2.5-pro                128000 vision tools
  RESPONSES_ONLY mai-code-1-flash-picker       256000 tools reasoning

  OK              usable via /chat/completions — emitted into providers.yaml
  NOT_SUPPORTED   catalogue lists it, the account is not entitled to it
  RESPONSES_ONLY  exists, but only on /responses — Raycast cannot reach it
```

（上面是 22 列裡的節錄。實測 2026-07：9 個 OK、6 個 NOT_SUPPORTED、7 個
RESPONSES_ONLY。）掃描以 `COPILOT_RAYCAST_JOBS`（預設 6）並發，每個模型有一次免費重試
吸收突發的 429/502 —— 沒有的話一次抖動就會把一個好模型靜默地從檔案裡刪掉。

### `copilot-raycast doctor`（別名：`test`）

```
copilot-raycast doctor   base http://localhost:4142/v1   config /Users/david/.config/raycast/ai/providers.yaml

Prerequisites
  ✓ curl             /usr/bin/curl
  ✓ jq               /usr/local/bin/jq
  ✓ yq               /usr/local/bin/yq

Proxy
  ✓ listening        http://localhost:4141
  ✓ throttle shim    http://localhost:4142 — base_url points here

Raycast
  ✓ installed        /Applications/Raycast.app  v1.104.23
  ✓ custom providers experiment has been enabled (template installed)
  ✓ loaded models    9 live in the picker for provider 'copilot'

Config
  ✓ present          /Users/david/.config/raycast/ai/providers.yaml
  ✓ parse            valid (providers present, every model has id/name/int context)

Models
  ✓ probe            9 of 22 chat models usable
  ✓ drift            the 9 model(s) in the file match the live catalogue
  · cache            copilot-api caches /models at start — 'copilot-proxy restart' if stale

all checks passed (0 warning(s))
```

任何一項失敗就以非零狀態結束。`custom providers` 那一項是啟發式：偵測
`providers.template.yaml` 是否存在（Raycast 第一次打開該實驗功能時會從 bundle 釋出它），
所以文案是「experiment **has been** enabled」而不是「目前是開的」—— 那個 toggle 沒有
公開 API。

### `copilot-raycast edit`

用 `$EDITOR` 開設定檔，**存檔後重新驗證**。改壞了會明確報錯並提示 `generate` 或從備份
還原，而不是讓你在 Raycast 裡對著空空如也的模型選單發呆。檔案不存在時直接以 1 結束。

## 設定

| Env var | 預設 | 意義 |
|---|---|---|
| `COPILOT_RAYCAST_CONFIG` | `$XDG_CONFIG_HOME/raycast/ai/providers.yaml` | Raycast 監看的檔案 |
| `COPILOT_RAYCAST_ID` | `copilot` | 這個工具擁有的 `providers[].id`；檔案裡**其他**每個 id 都會被保留 |
| `COPILOT_RAYCAST_LABEL` | `GitHub Copilot` | `providers[].name` |
| `COPILOT_RAYCAST_SUFFIX` | `" (Copilot)"` | 接在每個模型顯示名稱後面，讓你在選單打 `copilot` 一次撈到全部 |
| `COPILOT_RAYCAST_TEMP` | `auto` | `auto｜on｜off` —— 覆寫 temperature 啟發式（它探不出來） |
| `COPILOT_RAYCAST_JOBS` | `6` | 掃描時的並發探針數 |
| `COPILOT_RAYCAST_PROBE_BASE` | `$(_copilot_base)`（`:4141`） | 探針 POST 的目標；刻意**不**走 shim |
| `COPILOT_RAYCAST_KEEP` | `10` | 保留幾份時間戳備份 |

這些設在 `~/.shellrc.adhoc`（或 `~/.config/{zsh/secrets.zsh,bash/secrets.sh}`）。

## 陷阱 (gotchas)（這些都花了實際 debug 時間）

### Raycast 對 `providers.yaml` 是全有全無驗證，失敗時什麼都不說

一個模型少了 `context`、或者寫成 `context: "128000"`（Swift 那邊是型別不符），就會讓
**每一個** custom provider 從選單裡消失 —— 包含跟這個檔案毫無關係的其他 provider。
沒有錯誤訊息、沒有紅字、沒有 log。

所以 `generate` 一定先渲染到暫存檔、用 `yq` 驗證（至少一個 provider、provider id 不重複、
每個模型都有 `!!str id`、`!!str name`、`!!int context`），通過才 `mv` 就位。手改請一律
用 `copilot-raycast edit`（它會幫你重驗），或者改完馬上 `copilot-raycast status` 看
`raycast` 那一行的數字。

### `model_picker_enabled: true` 不代表模型真的能用

`claude-sonnet-4-5` 在 `/v1/models` 裡 `model_picker_enabled: true`、
`policy.state: "enabled"`、`supported_endpoints` 明寫 `"/chat/completions"` ——
送出去回 `model_not_supported`。反過來 `gemini-2.5-pro` 的 `supported_endpoints` 是
`null`，卻完全能用。用 metadata 過濾就是這兩邊一起錯。詳見上面的
[零額度探針](#零額度探針-zero-quota-probe)。

### 模型沒出現在選單裡，通常是整份檔案被打回，不是那個模型不見了

先問「Raycast 到底載入了什麼」，不要先猜。`raycastAI_modelRouterModelInfo` 是一團
base64 JSON，key 就是 provider id，內容是 Raycast **實際接受**的模型：

```sh
plutil -extract raycastAI_modelRouterModelInfo raw -o - \
  ~/Library/Preferences/com.raycast.macos.plist | base64 -d | jq -r '.copilot[].model'
```

空的 → 檔案被拒（或 Raycast 從沒讀過它）。有東西但少了幾個 → 那才是真的少模型。
`copilot-raycast status` 與 `doctor` 讀的就是這個，所以「靜默被拒」變成看得見的一行。

### 真的送訊息時才吃到 `model_not_supported`

Raycast 在載入設定時不打網路，所以壞掉的 id 在選單裡看起來一切正常，直到第一則訊息。
代表檔案過期了 —— GitHub 收回了某個模型的權限。修法：

```sh
copilot-raycast diff              # 看差在哪
copilot-raycast generate          # 重新探針 + 重寫
```

### proxy 的 `/models` 只在啟動時抓一次 —— 目錄過期時重跑 generate 也沒用

`copilot-api` 只在**行程啟動時**抓一次目錄，然後快取整個生命週期。所以「重新 generate」
拿到的還是同一份壞掉的清單。`doctor` 的最後一行就是在提醒這件事。先重啟 proxy：

```sh
copilot-proxy restart && copilot-raycast generate
```

出口被 geo-filter 也會造成同一種症狀（Claude 模型整組消失）—— 完整說明見
[proxy 文件的模型清單章節](copilot-claude-proxy.zh-TW.md#模型清單只在啟動時抓一次--直連被-geo-filter--一次抓壞整個-session-就毀了)
與
[`pitfalls/copilot-api-caches-degraded-model-list-at-startup.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-api-caches-degraded-model-list-at-startup.md)。

### Raycast 的檔案監看會合併連續寫入，有機會整個跳過重新載入

所以安裝流程刻意只有**一次寫入**（`mv`），而且備份是寫到
`~/.local/state/copilot-raycast/backups/` 這個**別的目錄**，而不是在設定檔旁邊留一個
`.bak` —— 那會構成第二次 touch。如果你自己用腳本寫這個檔案，請沿用同樣的作法：先寫暫存
檔，再一次 `mv`。

### 內建的 **Web** 與 **DALL·E** extension 永遠不可能配 custom provider

本機安裝的 AI Extension 是正常的 —— `Location` 會被呼叫、在你的 Mac 上執行、回傳結果。
但內建的 **Web** extension 永遠顯示警告三角形加
*"Extension is not supported for this model"*，而且改任何 YAML 都救不回來。

這是架構限制。Raycast 的 binary 裡剛好只有兩個 extension 叫 `remote_package_*` ——
`remote_package_web` 與 `remote_package_dalle` —— 其餘全部是 `builtin_package_*`
（`browser`、`clipboard`、`github`、`jira`、`linear`、`media`、`reminders`、`zoom`……）。
remote 這一對是在 Raycast 自己的基礎設施上執行的，而 custom provider 的請求根本不會
經過那裡：Raycast 自己的介面就寫著這些請求是
*"routed directly to the provider's servers"*。讓 `localhost` 打得到的那個特性，
正好也讓託管的 tool 打不到。

**沒有任何 ability key 能打開它。** `web_search: { supported: true }` 做過單一模型的
A/B 實驗，結果是被無聲忽略。設定檔解析器真正會讀的 key 是
`RaycastApp/AIProvider+Additions.swift` 底下一段連續的字串表：

```
models  api_keys  base_url  context  abilities → { tools, vision, system_message }
```

`temperature` 與 `reasoning_effort` 同樣被接受（兩者都出現在 Raycast 官方的 Enterprise
`providers.yaml` 範本裡）。`web_search`、`image_generation`、`structured_outputs`
屬於*別的* struct —— Raycast 託管模型的 catalogue 以及它的 OpenRouter client ——
不屬於 `providers.yaml`。所以 `copilot-raycast` 不會產生這些 key。

替代作法：裝一個在本機執行、自帶 API key 的搜尋 extension（Exa Search、Tavily……），
用 `@` tag 呼叫。注意 extension 必須在那個 chat 的 **AI Extensions** 清單裡、或是被
`@` tag 到，模型才拿得到 —— 只在 Settings → Extensions 裡啟用是不夠的。這也是為什麼
`Ask Weather` 明明啟用了，模型還是會回*「我沒有 weather tool」*。

## 替代路線：Ollama Host + Ollama 協定 shim

Raycast Settings → AI 還有一個 **Ollama Host** 欄位，社群方案（例如
[raycast-ai-openrouter-proxy](https://github.com/miikkaylisiurunen/raycast-ai-openrouter-proxy)）
就是**假扮成 Ollama server**，再把請求翻譯成任何 OpenAI 相容 (compatible) 的後端。

這裡**不推薦**這條路：它要多跑一個 Docker 服務、多一層協定翻譯（Ollama ↔ OpenAI）與一份
自己的 `models.json`（改完要重啟），本身自稱 *Work In Progress*，而且沒有內建認證。
Custom Providers 走的是原生 OpenAI schema、零額外行程、直接吃我們已經在跑的 proxy，
而 `copilot-raycast` 又能從即時目錄自動維護那份 YAML —— 沒有理由多插一層。

## 驗證

```sh
copilot-raycast doctor                       # → all checks passed (0 warning(s))
copilot-raycast diff                         # → no changes (… is current)
yq '.providers[].models[].id' ~/.config/raycast/ai/providers.yaml   # → 9 個 id
plutil -extract raycastAI_modelRouterModelInfo raw -o - \
  ~/Library/Preferences/com.raycast.macos.plist | base64 -d | jq -r '.copilot[].model'
#   → 同一組 9 個 id ＝ Raycast 真的收下了（不只是「檔案寫出去了」）
```

## 延伸閱讀

- [Copilot → Claude Code 代理 (proxy)](copilot-claude-proxy.zh-TW.md) —— 這裡指向的
  proxy（認證、模型 id、throttle shim、ToS、陷阱）
- [Copilot embeddings → 語意搜尋](copilot-embeddings.zh-TW.md) —— 同一個 proxy 的
  `/v1/embeddings` 端點
- [`copilot-raycast` 的 alias 表](../shells/aliases.md#copilot-agent-gateway)
  —— 一行版摘要與來源檔
- [Raycast manual — Bring Your Own Keys](https://manual.raycast.com/ai/bring-your-own-keys)
  ——「processed through our servers」那句話的出處，也就是本文第一節那個坑
- [Raycast manual — AI → Custom Providers (Bring Your Own Models)](https://manual.raycast.com/v1/ai#custom-providers-bring-your-own-models)
  —— per-user 那條路，也是 app 裡「Learn more about custom providers」按鈕開的頁
- [Raycast manual — Custom provider (Teams)](https://manual.raycast.com/teams/custom-provider.md)
  —— *Enterprise Exclusive* 的組織版檔案，會蓋掉成員本機那份；schema 相同
- [Ernest0-Production/raycast-ai-custom-providers](https://github.com/Ernest0-Production/raycast-ai-custom-providers)
  —— 用 GUI 編 `providers.yaml` 的 Raycast extension（會自動備份）；
  [aadishv.dev 的 Raycast + Copilot 筆記](https://www.aadishv.dev/raycast-copilot/)
  是同一條路徑的手動版本
