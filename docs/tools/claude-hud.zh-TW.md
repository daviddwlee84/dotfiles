# claude-hud（Claude Code statusline）

[claude-hud](https://github.com/jarrodwatts/claude-hud) 負責渲染 Claude Code
prompt 上方那幾行 HUD：model badge、context bar、cost、cache 倒數、工具活動、git 狀態。

這一頁講的是**如何正確解讀那些數字**。其中好幾個的意義跟外表不同，而且有兩個數字
會合理地互相矛盾。安裝／升級機制見 [upgrades.md](../this_repo/upgrades.md)；
`enabledPlugins` 的決定見 [lsp.md](lsp.md) § 透過 Claude Code 外掛。

## 接線位置

| 項目 | 位置 |
|---|---|
| 設定（SSOT） | [`dot_claude/plugins/claude-hud/config.json`](../../dot_claude/plugins/claude-hud/config.json) —— 純受管檔案；直接改實機檔案會在 `chezmoi apply` 時被還原 |
| `statusLine.command` | [`dot_claude/modify_settings.json.tmpl`](../../dot_claude/modify_settings.json.tmpl) 裡的 `overlay` heredoc |
| 安裝／刷新 | [`claude_hud_sync.py`](../../dot_ansible/roles/coding_agents/files/claude_hud_sync.py)，經由 `just upgrade-plugins` |
| 完整 flag schema | 帶版本的快取目錄裡的 `src/config.ts` |

這個 plugin 在 `enabledPlugins` 中是**刻意停用**的。HUD 依然會渲染，因為
`statusLine.command` 直接 glob 快取路徑並執行 `dist/index.js`，完全不經過外掛載入器。
唯一的代價是 `/claude-hud:setup` 與 `/claude-hud:configure` —— 而你本來也不該用它們，
因為它們寫入的東西會在下次 apply 被還原。請改設定原始檔。

## `Tokens` 是累計值，不是水位

最容易誤解的數字。在 1M context 的 session 上，你會常態看到類似 `Tokens 22.5M`。

claude-hud 是把 **transcript 裡每一則 assistant 訊息**的 `message.usage` 加總
（`sessionTokens.inputTokens += …`），也就是 session 中每一次 API request。
LLM 推論是無狀態的，所以每一輪都要重送整段對話 —— 第 100 輪的 prefix 會被算第 100 次。

以本 repo 一份真實 transcript 實測：

```text
508 API responses, 1 compaction
CUMULATIVE SUM  : 103.88M   <- HUD 印出來的就是這個
  in=92k  out=831k  cache_create=4.66M  cache_read=98.30M
PEAK SINGLE REQ : 383k      <- 唯一受 context window 限制的數字
ratio           : 271x
```

這個比值大致就是「輪數 × 平均 context」。沒有任何異常發生，而且**不是 compaction 造成的**
—— 508 次 request 只有 1 次 compaction，何況 compaction 的效果是*降低*後續 context。

想看真正被 context window 限制的數字，請看 `Context` bar（`218k/1.0M`），而不是 `Tokens`。

## `Tokens` 只計算主執行緒

subagent 與 workflow 的回合**不在** Claude Code 由 stdin 交給 statusline 的那份
transcript 裡。它們位於同層的另一個目錄：

```text
~/.claude/projects/<project>/<session-id>.jsonl              <- 主執行緒，HUD 讀的是這個
~/.claude/projects/<project>/<session-id>/subagents/agent-*.jsonl   <- 從不讀取
```

主檔案裡也不會出現任何 `isSidechain` 紀錄。以本機一個真實 session 實測：
**主執行緒 1,333,449 tokens 對上 subagent 814,250 tokens** —— HUD 少報約 38%。
你 fan out 得越多，落差越大。

## `Cost` 沒有這個盲點

`Cost` 與 `Tokens` 來源不同，這正是它們看起來互相矛盾的原因。`src/cost.ts` 優先採用
原生數值，只有在沒有時才退回本地估算：

```js
const nativeCostUsd = getNativeCostUsd(stdin, options);
if (nativeCostUsd !== null) return { totalUsd: nativeCostUsd, source: 'native' };
const estimate = estimateSessionCost(stdin, sessionTokens, options);  // fallback
```

- **native** —— Claude Code 自己放在 stdin 的 `cost.total_cost_usd`。訂閱 session 走的是這條。
- **estimate** —— 由 `sessionTokens` 推導，所以*會*繼承上面的主執行緒盲點。只有在 stdin
  沒帶 cost 時才會用到。

Claude Code 端的累加器對每個 request 都無條件累加：

```js
if (e.totalCost += r, e.requestCount++, t.attributionAgent)
    zUo(e.byAgent, t.attributionSkill ?? t.attributionAgent, r)
```

`attributionAgent` 只是驅動 per-agent 拆帳，並不會擋住總額。所以
**`Cost` 包含 subagent 與 workflow，`Tokens` 不包含。** 兩者不一致時，`Cost` 才是完整的。

### 這是實測，不是推論

一次受控實驗可以同時釘死兩邊。強制主執行緒用 haiku、subagent 用 sonnet，
再讀 `--output-format json`：

```console
$ claude -p --output-format json --model claude-haiku-4-5-20251001 \
    'Use the Agent tool with subagent_type "general-purpose" and model "sonnet" …'
```

```text
total_cost_usd                        0.13825985
  claude-haiku-4-5  （主執行緒）        0.06095585
  claude-sonnet-5[1m]（subagent）      0.077304
                                      ──────────
  合計                                 0.13825985   精確吻合
```

subagent 佔了帳單的 56%，且毫無疑問被計入。而 transcript 那側呈現相反的結果：

```text
MAIN transcript  （claude-hud 唯一讀的檔案）
   models = ['claude-haiku-4-5-20251001']
<session-id>/subagents/agent-*.jsonl  （從不讀取）
   models = ['claude-sonnet-5']
```

subagent 的 model 從未出現在主 transcript，卻出現在 `modelUsage` 與成本中。
一個實驗，兩個結論。

> 若直接對主 transcript 的 `usage` 做天真加總，會得到約 `modelUsage` 數字的 1.7 倍，
> 因為 Claude Code 會把同一個 API response 重複寫進 transcript 2–3 次。
> claude-hud 是以 `message.id` 去重的（見 `src/transcript.ts` 的註解）；
> 臨時腳本若不比照辦理就會多算。

## Cache：只存在於 input 側，而倒數是快照

### 沒有 output cache

Anthropic 的 prompt caching 只作用在 **input prefix**。四個 usage 欄位：

| 欄位 | 意義 | 概略計價 |
|---|---|---|
| `input_tokens` | 未命中快取的新 input | 1× |
| `cache_creation_input_tokens` | **寫入**快取的 prefix | 1.25× |
| `cache_read_input_tokens` | **讀自**快取的 prefix | **0.1×** |
| `output_tokens` | 生成的 token | 輸出價 |

這就是為什麼上面的分佈是 `in=92k` 對上 `cache_read=98.30M`：第一次 request 之後，
幾乎整段 prefix（system prompt、工具定義、歷史）都命中快取，只有最新的增量是新的。

output 本身從不以 output 形式被快取 —— 但這一輪的 output 會成為下一輪 input prefix
的一部分，*那時*才變得可快取。這是生成內容進入快取的唯一途徑。

### 閒置時倒數會凍住 —— 這是設計，不是 bug

`showPromptCache` 渲染的是一個在渲染當下求值的純算式
（`src/render/lines/prompt-cache.ts`）：

```js
const remainingMs = (lastAssistantResponseAt.getTime() + ttlSeconds * 1000) - now;
```

claude-hud 內部沒有計時器。數值只有在 **Claude Code 重新呼叫 statusline 指令**時才會變，
而它是在狀態改變時呼叫（debounce 300 ms），從不依照牆上時鐘。因此：

- **回合進行中**它會傾向停在 `5m 0s` 附近，因為 `lastAssistantResponseAt` 會隨每則
  assistant 訊息前進，而 agent 回合每幾秒就產生一則。它是真的在重置，不是卡住。
- **回合結束後**沒有任何事件觸發重繪，所以最後算出來的字串就凍結在畫面上。

倒數本身是活的 —— 手動對固定的 transcript 每隔四秒呼叫一次，會看到
`5m 0s → 4m 56s → 4m 52s`。真正的限制恰好與需求相反：它無法在你閒置時告訴你快取快過期了，
而那正是你最需要它的時候。請把它理解成「上一次渲染時快取有多新」。

金錢上的意義：讓 TTL 過期意味著 prefix 會以 `cache_creation`（1.25×）而非
`cache_read`（0.1×）重新計費 —— 在 prefix 上是 12.5 倍的差距。`promptCacheTtlSeconds`
預設 300，應與你的 request 實際使用的 TTL 一致。

## 第一行的截斷遵循固定順序

segment 依此原生順序渲染，並在終端寬度處被切斷：

```text
model, project, advisor, sessionName, version, extra, duration, cost, speed, auth
```

`cost` 排在 10 個中的第 8 個，所以它會是最早消失的項目之一 —— 你會看到 `Cost $…`
而一個隨機 session slug 反而活著。不要用關掉元素來解決，改成重新排序。
`orderFirstLineParts` 會依你給的順序輸出列出的 segment，並**把所有未列出的 key 接在其後**，
所以 partial list 就夠用，而排在最後的就是被截斷時最先犧牲的：

```json
"projectLineOrder": [
  "model", "project", "duration", "cost",
  "extra", "advisor", "speed", "auth",
  "sessionName", "version"
]
```

`modelFormat: "compact"` 還能再移除 `(1M context)` 後綴 —— Context 那行本來就已經寫著
`218k/1.0M`。

## 除非你替 session 命名，否則 `sessionName` 只是隨機 slug

`magical-noodling-horizon` 這類名字是 fallback，不是識別碼：

```js
result.sessionName = customTitle ?? latestSlug;
```

`customTitle` 來自 `claude -n <name>` / `--name <name>`，CLI 的說明是
*"Set a display name for this session (shown in the prompt box, /resume picker,
and terminal title)"*。沒下這個參數就會拿到自動產生的 slug。

它與 `--resume` 實際依據的 **session UUID 無關**。它純粹是給 `/resume` 選單和終端標題
看的人類標籤 —— 在你開始使用具名 session 之前都只是雜訊，之後則會成為最快找回 session 的方式。

## 相關

- [upgrades.md](../this_repo/upgrades.md) —— 版本漂移、install-only 陷阱，以及
  `0.0.11` 之後新增的完整 opt-in 元素清單
- [lsp.md](lsp.md) —— `enabledPlugins` 對應表
- [`pitfalls/claude-hud-shows-raw-model-id.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/claude-hud-shows-raw-model-id.md)
  —— badge 顯示原始 `claude-opus-5[1m]` 代表 Claude Code 太舊、沒送 `display_name`
- [`pitfalls/claude-hud-usage-statusline-stale.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/claude-hud-usage-statusline-stale.md)
