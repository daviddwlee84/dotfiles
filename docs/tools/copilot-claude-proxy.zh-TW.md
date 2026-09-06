# Copilot agent gateway（Claude Code + Codex）

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

用 **GitHub Copilot** 訂閱目前 served 的模型來驅動
[Claude Code](https://code.claude.com/docs/en/overview)：帳號有 Claude entitlement 時優先
用 Claude，沒有時改用有角色分層的 OpenAI fallback。本機代理使用持續維護的
[`caozhiyuan/copilot-api`](https://github.com/caozhiyuan/copilot-api)
fork（npm `@jeffreycao/copilot-api`）。

- **Shell helpers**：`~/.config/shell/43_copilot_proxy.sh`（`copilot-proxy`、
  `claude-copilot`、`codex-copilot`、`copilot-run`、`copilot-here`、
  `copilot-model`）
- **執行器 (runner)**：`@jeffreycao/copilot-api`（已釘選 pinned），**只安裝一次**到
  `~/.local/share/copilot-api/pkg`，之後直接執行該處的 binary。刻意**不**在啟動時用
  `bunx`：bunx 每次啟動都會重新解析套件，而 bun 透過 socks `ALL_PROXY` 解析相依會永遠卡住
  —— 詳見[陷阱](#start-used-to-hang-at-resolving-dependencies-behind-a-socks-proxy)。
  熱啟動 (warm start) 在綁定 port 之前完全不碰網路。
- **不由 ansible 安裝** —— 第一次 `copilot-proxy start` 才安裝。`update --check`
  只檢查；只有明確指定 `copilot-proxy update VERSION` 才會改變釘選版本。

!!! warning "這違反 GitHub Copilot 的服務條款 (Terms of Service)"
    用 Copilot 訂閱去驅動非 GitHub 的 agent 是不被允許的，且 copilot-api 是逆向工程/非官方
    的。copilot-api 自己的 README 就警告它可能觸發 GitHub 的 **濫用偵測 (abuse detection)**，
    導致 **Copilot 存取被暫時停權 (temporary suspension)**。Claude Code 很吃 token（頻繁的背景
    請求、大 context）；fork 本身沒有 rate limiter，所以本機 shim 以保守 queue + 自適應並行
    控制 burst，另可設 `COPILOT_PROXY_QUIET=1` 減少背景呼叫。兩者都不是上游保證的安全上限。
    風險自負；建議用個人帳號而非公司席位 (corporate seat)。

## 快速開始

```sh
copilot-proxy auth      # 一次性：GitHub 裝置登入 (device login)（儲存 ghu_ token）
copilot-proxy start
copilot-model --auto    # 有 Claude 就用 Claude，否則按 Sol/Terra/Luna 角色配置

claude-copilot          # 一次性 session 走代理（自動啟動代理；不寫任何檔案）
claude-copilot --fast   # 同上；catalog 有 fast sibling 時改走該模型
claude-copilot-once     # 釘住「這個專案」跑一次 session，結束自動解除（代理需已啟動）
codex-copilot           # 一次性 Codex session；auto 優先選 OpenAI
codex-copilot-once      # 完全相同的 alias；兩者都不寫 Codex config

# 單次 planning preset。Codex TUI 開啟後仍需輸入 `/plan`；
# Codex 0.151.0 沒有啟動時指定 collaboration mode 的公開 flag。
codex-copilot -c 'plan_mode_reasoning_effort="ultra"' -c 'service_tier="fast"'
claude-copilot-once --fast --permission-mode plan --settings '{"ultracode":true}'

copilot-here on         # 或者：釘選「這個專案」—— 之後直接跑 `claude` 就走代理
copilot-here off        # 取消釘選 —— 回到真正的 Anthropic 後端
```

Claude 指令不要再加 `--effort`：啟動時的 effort pin 會阻止 session-only
`ultracode` 生效。Codex 的兩個 override 只影響本次啟動；開啟後輸入 `/plan`
才會正式進入 Plan mode。

## 運作原理

```
Claude Code ──Anthropic /v1/messages──▶ throttle/metrics shim (:4142) ─▶ copilot-api (:4141)
                                          │ Claude：native Messages path
                                          │ GPT：Anthropic → Responses 轉譯
                                          ▼
                                   api.githubcopilot.com  （你的 Copilot 訂閱）

Codex ──OpenAI /v1/responses──────────▶ 同一個 :4142 managed gateway
        （provider/model 只透過本次啟動的 `-c` / `-m` 覆寫）
```

- Claude Code 只講 **Anthropic Messages API**（`/v1/messages`）。
- fork 對 Claude id 使用 Copilot native Anthropic path；對 GPT id 把 Claude Code
  request 轉成 **Responses API**。目前釘選的 `2.3.4` 會把 `output_config.effort` 正確轉成
  `reasoning.effort`，並支援 GPT-5.6 request shape 與 reasoning state。
- Claude Code 透過 `ANTHROPIC_BASE_URL` 被指向代理 —— 注入方式有兩種：
  per-process 環境變數（`claude-copilot`），或 gitignore 掉的
  `./.claude/settings.local.json`（`copilot-here on`）。見「設定分層設計」。

## 設定分層設計（代理設定該放哪一層、為什麼）

Claude Code 由低到高合併設定：`~/.claude/settings.json`（user）→
`./.claude/settings.json`（project，會 commit）→ `./.claude/settings.local.json`
（local，gitignored）→ CLI flags。實測中 `settings.local.json` 的 `env` 可以蓋過繼承的
shell env，所以已開 `copilot-here` 時，`claude-copilot` 不會強行覆蓋它。

其中兩層已有其他工具負責，必須保持乾淨：

| 層 | 擁有者 | 為什麼代理設定「不能」放這裡 |
|---|---|---|
| `~/.claude/settings.json` | chezmoi（`dot_claude/modify_settings.json.tmpl`） | 會讓 *每個* 專案永遠走代理；還會跟 chezmoi 的合併打架。頂層 `model` 不得保留只供代理使用的 GPT/Gemini id。 |
| `./.claude/settings.json` | `claude-plans-here`（`plansDirectory`） | 會 commit 進 git —— 代理設定會外洩給整個團隊 |

所以代理使用沒人佔用的兩層：

| 啟用 | 機制 | 範圍 | 停用 |
|---|---|---|---|
| `claude-copilot` / `copilot-run` | per-process 環境變數 | 單一 session | 下次直接跑 `claude` 即可 |
| `claude-copilot-once` | 暫時 `settings.local.json` pin | 單一 session | session 結束自動還原 |
| `copilot-here on` | `./.claude/settings.local.json`（gitignored） | 這個專案、持續生效 | `copilot-here off` |

```
~/.claude/settings.json          .claude/settings.json         .claude/settings.local.json      shell env
(chezmoi: hooks/plugins)    <    (git: plansDirectory)     <   (copilot-here on/off)        <   (claude-copilot)
```

上游有一個 UI 動作會跨越這個 ownership：在 Claude Code `/model` 選單按 **Enter**
代表「設為預設」，會把 custom id 寫進 `~/.claude/settings.json`。這個寫入不會隨
per-process launcher 結束，也不會被原本的 `copilot-here off` 移除。因此 launcher 現在只
guard 頂層 `model`：結束時移除 proxy-only 值，或還原原本的 native 值；hooks/plugins/
permissions 與 session 中其他合法設定變更全部保留。即使 local pin 檔本來就不存在，
`copilot-here off` 也會清除殘留的 proxy-only user model。

## Shell helpers

### `copilot-proxy [start|stop|status|stats|events|limiter|logs|quota|bench|update|...]`

在 `$COPILOT_PROXY_PORT`（預設 `4141`）管理背景代理。

| 環境變數 | 預設 | 意義 |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | 代理監聽的 port |
| `COPILOT_HTTP_PROXY` | `auto` | GitHub `/models` 用的上游 HTTP proxy：`auto`（本機 Clash/Verge/mihomo 有在聽就帶 `--proxy-env`）、`never`（直連）、`always`（一定要偵測到 proxy）、或明確 URL |
| `COPILOT_API_PKG` | 未設定 | 最高優先的暫時套件覆寫；否則使用已保存的 exact selection，再 fallback 到內建 `@jeffreycao/copilot-api@2.3.4`。設著時 `update VERSION` 不會改 persisted state。 |
| `COPILOT_PROXY_RATE` | `15` | 僅舊版 `copilot-api@0.7.0` 使用；fork 沒有 rate limiter |
| `COPILOT_SHIM_MIN` | `4` | 自適應並行 floor，也是啟動 limit |
| `COPILOT_SHIM_MAX` | `8` | 自適應 ceiling；設成與 `MIN` 相同即可固定上限 |
| `COPILOT_PROXY_QUIET` | `0` | `1` 減少背景模型呼叫，但會犧牲部分 UX |
| `COPILOT_INSTALL_NOPROXY` | `0` | `1` = 安裝時把 proxy 環境變數拿掉，跳過「bun 無法透過 proxy 解析」那 45 秒的卡頓 |

這些設在 `~/.shellrc.adhoc`（或 per-shell secrets 檔案）。在 `copilot-proxy auth`
儲存 token 之前，`start` 會拒絕執行；啟動後最多等 ~20 秒直到代理能回應才返回。

**第一次** `start` 會把釘選的套件安裝到 `~/.local/share/copilot-api/pkg`（並寫下 spec
戳記），之後每次啟動只是直接執行那個 binary —— 不打 registry、不做啟動時解析。安裝時會
先用你當下的環境變數（在「registry 只能透過 proxy 連到」的機器上必要），卡住就改用拿掉
proxy 的重試；兩種嘗試都有 timeout 並會被殺掉，所以卡死的安裝再也不可能占住 bun 的全域
快取鎖而拖垮下一次。`start` 逾時的時候現在也會**把自己啟動的 server 殺掉**，不會像以前
那樣每重試一次就留下一個孤兒程序。

`copilot-proxy quota [--json]`（`whoami` 仍是 alias）讀取即時 plan / quota；fork 上使用
與 `/usage-viewer` 相同的 `/usage` payload，代理未執行時不會假裝有離線 quota。

### 正常流量統計與安全 benchmark

managed Claude/Codex launcher 預設全部經過 shim。shim 啟用但啟動失敗時會 fail closed，
不會靜默 fallback 到 `:4141`；`copilot-proxy shim off` 是明確的 break-glass 直連模式。

在 upstream model bytes 尚未暴露前，shim 會對 network failure 或 HTTP
403/429/500/502/503/504 重試**相同 buffered request 與 model**。上游讀取 buffered body
時回 `408 user_request_timeout` 最多只重播一次，持續的大 request failure 不會吃滿一般 retry
budget；HTTP 402、bare 401 與 policy 422 只通過一次。Queue waiter 與 retry backoff 都會回應 client cancel，放棄的 request 不會繼續
佔住 permit。所有成功的 streamed response（包括 grace window 內的快速回應）都必須是
SSE media type。慢 stream 在 queue/retry 期間持續收到 SSE comment；如果這段 pre-header
pipeline 最後得到 non-2xx 或不是 SSE 的 HTTP 200，shim 會依 Anthropic Messages 或
OpenAI Responses 的 terminal error shape 送出，不會把 raw JSON 接在 comment frames 後面。
Responses 會把 402 分類為 quota、429 分類為 rate limit、其他 post-commit 4xx 分類為
invalid prompt，5xx/transport failure 則分類為 server error，避免 Codex 重試不可重試的
錯誤。延遲 bare 401 只能用 `invalid_prompt` 作為 stopgap，因 Codex 沒有不可重試的 Responses
authentication code；只有尚未 commit 前的原始 HTTP 401 能保留 authentication semantics。
一旦 model bytes 已開始，後續 body error/stall 只會終止 stream，不再 retry。
`422 cyber_policy` 是 provider 的內容政策判定；shim 不 retry、不改寫，也不嘗試繞過。

Admission control 現在是自適應，而不是固定 semaphore。啟動時從
`COPILOT_SHIM_MIN=4` 開始，只有在確實有人排隊且持續成功時，才逐格增加到
`COPILOT_SHIM_MAX=8`。上游一旦回 403/429 就立刻降回 floor 並冷卻五分鐘；
`Retry-After` 最多尊重五分鐘。設定 `MIN=MAX` 可得到固定上限。live 調整不會
中斷正在跑的 stream，也不必重啟：

```sh
copilot-proxy limiter status
copilot-proxy limiter set --min 4 --max 8 --limit 6
copilot-proxy limiter reset     # 回到啟動環境值；live 改動不持久化
```

寫入端點只接受 loopback，且要求 manager 專用 admin header。若要持久化範圍，
在 `~/.shellrc.adhoc` export `COPILOT_SHIM_MIN/MAX`，之後再重啟 shim。

```sh
copilot-proxy stats week --model gpt-5.6-sol
copilot-proxy events day --limit 20 --json
copilot-proxy quota --json
copilot-proxy bench --model gpt-5.6-sol --runs 3 --max-output 256
```

`stats` 預設只算一般使用；benchmark 要用 `--scope benchmark`，兩者合併則用 `all`。
輸出包含 request/error/retry，並把 client cancel 與 upstream failure 分開；另有 queue、
upstream headers、first byte、stream、end-to-end 的
p50/p90/max，以及 token、AIU、output token/s。只有完成的 stream 且能對到 token event
時才計算吞吐量，否則為 `null`。

shim 不儲存 prompt 或 response body，只把 timing 寫到
`$XDG_STATE_HOME/copilot-proxy/metrics.sqlite`（WAL、保留 90 天）。fork 的 dashboard 則讀
`$XDG_DATA_HOME/copilot-api/copilot-api.sqlite` 的 `token_usage_events`；它不保存 quota
歷史，`/usage` 是即時 GitHub 資料。CLI 以 `x-trace-id` join 兩個 DB，並先彙總同一
request/model 的多筆 token event。`stats`、`events` 在代理與 shim 都停機時仍可離線讀取。

`bench` 會送真實 streaming Responses request，確實消耗 quota；限制為 1–10 runs、
32–2048 max output tokens、concurrency 1–4，並獨立標記，不污染正常使用統計。

### 套件供應與明確更新

warm start 只執行已安裝 binary，不接觸 npm，因此 registry 下架只影響新機、重裝或更新。
成熟 npm 套件一般下架門檻較高，但 maintainer、政策與 Copilot protocol 改變的風險仍存在；
它畢竟是非官方且 maintainer surface 小的套件。

`update --check` 優先查 canonical npm，失敗才帶警告使用 configured registry，且絕不安裝。
`update VERSION` 只接受 exact semver，驗證 npm tarball SHA-512 integrity，在 staging prefix
安裝並 smoke-test 後 atomic swap，保留 `pkg.previous`。若原本正在跑，而新版 swap 後健康
啟動失敗，會還原舊 prefix 與 selection 並重啟。selection JSON 位於
`$XDG_STATE_HOME/copilot-proxy/package.json`。

經審核的內建 release 是 `@jeffreycao/copilot-api@2.3.4`：tag commit
[`a515535`](https://github.com/caozhiyuan/copilot-api/commit/a51553569ba071e0c9a8329f8f5ccac2482a3945)、
npm tarball SHA-1 `643f59e0c257db613954738f02300c0a7ceebfeb`、SRI
`sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ==`、
35 個檔案，以及 npm Trusted Publisher provenance
[release run 32856658249](https://github.com/caozhiyuan/copilot-api/actions/runs/32856658249)。
已有 persisted 舊 selection 的 host 必須明確執行 `copilot-proxy update 2.3.4`；已驗證的
exact rollback target 仍是 `copilot-proxy update 2.3.0` 與 `copilot-proxy update 2.1.0`。

**一般安裝**（非 `update`）時，會把釘選的 selection 與 prefix 內實際落地的版本互相驗證。
`package-lock.json` 只在它記錄的 `version` 與已安裝版本相同時才採信：這個 prefix 天生是
mixed-manager —— `bun add` 只寫 `bun.lock`，npm CA-stack fallback 才寫 `package-lock.json`
而且沒有任何路徑會刪掉它 —— 所以舊 lock 描述的往往是早就不在的版本。少了這道版本閘門，
檢查等於拿兩個不同版本各自「真實」的 hash 互比，於是每次 start 都被擋下
（[pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-stale-package-lock-integrity.md)）。
沒有可用 lock 時，退回比對 npm registry 上**已安裝版本**的 metadata。兩種拒絕訊息都會印出
`on disk:` 與 `pinned:`。

### `copilot-proxy doctor [--live]`（別名：`test`）

診斷整條路徑，任何一項失敗就以非零狀態結束。預設**唯讀**；加上 `--live` 會多送一個真實的
`POST /v1/messages`（`max_tokens: 1`、挑一個非 `[1m]` 的 chat model），會消耗一個 quota
單位，但那是唯一能驗證 streaming 的檢查。

檢查順序：前置工具（`bun`/`curl`/`jq`）→ **套件 (package)** → token 檔案 → 代理與
throttle shim 是否存活 → 安裝殘留（stale installer）→ **模型**→ 上游連線 →
本機代理 / VPN → **Codex Apps** → live inference probe。

**套件 (package)** 這一段報告釘選的 spec 是否已安裝在 prefix 裡、binary 在哪。顯示
「未安裝」不算失敗 —— 下一次 `start` 會自動裝一次。

**安裝殘留（stale installer）** 是[陷阱](#start-used-to-hang-at-resolving-dependencies-behind-a-socks-proxy)
那個坑的保險絲：平常若還有存活的 `bun add … copilot-api`，就代表某次安裝卡死了（bun 透過
socks proxy 解析相依會卡住），而且正占著 bun 的全域快取鎖。現在安裝流程自己會設 timeout
並殺掉卡死的程序，所以這一項應該永遠是空的；萬一真的觸發，doctor 會印出「清掉再重啟」的
一行指令。

其中「模型」這一段才是這個指令的價值所在。它把代理**目前提供的**模型清單，跟 GitHub
**此刻真正提供的**清單相比對 —— 這是唯一能區分 `400 model_not_supported` 兩種成因的方法：

| 代理有 claude？ | 上游有 claude？ | 判定 | 修法 |
|---|---|---|---|
| 沒有 | **有** | 快取過期 (stale cache) | `copilot-proxy restart` |
| 沒有 | 沒有 | 組織政策停用 Anthropic | 重啟**沒有用** |

它會同時驗證 main 與 Fable/Opus/Sonnet/Haiku aliases，包括 `[1m]` alias。某個過期的
background role id，會造成普通對話成功、workflow 卻 400。沒有 Claude entitlement 在可用的
OpenAI profile 存在時是 warning，不是整體失敗。

上游連線會同時探測 `api.enterprise.githubcopilot.com` 與 `api.githubcopilot.com`，直連
**以及**（若有設定）走 macOS 系統代理，所以 Clash/mihomo 規則黑洞掉其中一個 host 時會立刻
顯現。未帶認證的 `400`/`401` 算「連得到」—— 只有連線/讀取失敗才算故障。`doctor` 絕不會印出你的
token：憑證是透過 `curl -K -`（stdin）傳入，而非 argv，因為 argv 可被 `ps` 讀到。

使用 `--live` 時，Codex Apps 段落還會對
`https://chatgpt.com/backend-api/wham/apps` 分別做 direct 與 detected HTTP
proxy probe。這個 GET 不消耗 model inference quota，可把 `codex_apps` 啟動中斷與
localhost Copilot 路由拆開診斷。任何真實 HTTP status（包含 auth rejection）都代表
網路可達；timeout 與 TLS certificate failure 會分開顯示。`codex_apps` 是遠端
ChatGPT MCP，不是只供 Apple Silicon Codex Desktop 使用的 bridge。

### `claude-copilot [--fast] [--no-specstory] [claude args...]` —— 一次性 session

第一層：跑一次走代理的 Claude Code session，**完全不寫檔案**。代理沒回應時會自動
啟動它，然後以 per-process 的 `ANTHROPIC_*` 環境變數啟動 `claude`（shell 環境變數
蓋過所有 settings 檔的 `env` 區塊，所以即使專案沒開 `copilot-here` 也會生效）。

- 有安裝 specstory 時自動包成 `specstory run claude`（markdown 自動存檔 ——
  跟 `scode`/`svibe` 同一套慣例）；用 `--no-specstory` 退出。額外參數透過
  specstory 的 `-c "custom command"` 傳給 claude CLI：`claude-copilot -c`
  → 繼續上一個 session。
- **傳參數時會保留你設定的 `claude_cmd`。** specstory 的 `-c` 是「**取代**」
  provider 指令而不是「附加」，所以這裡會先取出 specstory 設定檔中生效的
  `claude_cmd`（專案 `./.specstory/cli/config.toml` > 使用者
  `~/.specstory/cli/config.toml` > 裸 `claude`），再把參數接在後面。這正是讓
  `claude_cmd = "claude --dangerously-skip-permissions"` 對
  `claude-copilot --resume <id>` 也生效、而不是只對沒帶參數的 `claude-copilot`
  生效的原因 —— 這兩者以前行為並不一致，詳見
  [`pitfalls/specstory-custom-command-drops-configured-flags.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/specstory-custom-command-drops-configured-flags.md)。
  `--no-specstory` 仍**完全不繼承那條 command**（不帶 alternate binary、resume flag 或
  額外 prompt），但 raw path 會自行維持相同的 trusted
  `--dangerously-skip-permissions` posture。使用者明確指定 `--permission-mode` / `--permission-prompts` / `--restricted` 時會取代 repo
  seeded bypass。自訂 project/user `claude_cmd` 不會被重寫：沒有 alternate mode 時 wrapper
  會在後面追加預設 bypass；custom command 內既有的 permission flags 由該 command 自行負責。
  這與 Windows wrapper 一致。
- 還原 = 不用手動還原；下次直接跑 `claude` 完全不受影響。Claude Code 自己仍可能在
  `/model` + **Enter** 時寫入一個全域 key；EXIT guard 會在正常、非零或 Ctrl-C 結束時
  移除 proxy-only 值或還原先前的 native default，session 中其他設定變更不回滾。

`claude-copilot --fast` 會用 shim 的 live fast-routing map 對應明確指定或預設模型，
只為這次 invocation 在最後加上 sibling model，不寫 Claude settings。若 Copilot 沒有
advertise eligible sibling，launcher 會警告並繼續使用 standard model。

### `claude-copilot-once [--fast] [--no-specstory] [claude args...]` —— 一次性釘選 session

第一層的用完即丟 + 第二層的可靠度：用 `copilot-here on` 釘住 **這個專案**，跑一個
`claude-copilot` session，結束時 `copilot-here off` —— 連 Ctrl-C 也會還原。當純環境變數
注入不夠力（因為 `settings.local.json` 位階高於 shell env，見陷阱章節）、但你又不想留下
一個黏著的 pin 時就用它。

- **前提條件：** 代理必須**已經**在跑 —— 跟 `claude-copilot` 不同，它**不會**自動啟動；
  代理沒回應時它只印出 `copilot-proxy start` 提示並回傳非零。
- **不動既有 pin：** 如果這個專案的 `copilot-here` 本來就是 `on`，結束時會原樣保留
  （不會去解除你沒要求解除的 pin）。如果那個 pin **過期了** —— 跟這次啟動實際會用的
  `copilot-here on <model>` 不一致，例如帳號已改走 OpenAI fallback、pin 還停在不可用的
  Claude id，或 pin 建立時還沒有 Fable key —— 它會印出差異，並詢問要就地更新還是保留。
  `--fast` 會在比較前先解析，所以 fast pin 不再提議把自己降回 standard sibling；standard
  pin 則顯示正確的 standard → fast 升級。預設答案是**保留**（stdin 非互動時自動保留）。
  差異的計算方式是拿現檔去 diff `copilot-here on` 會合併的那份 env 區塊
  （`_copilot_env_json`，兩邊共用的唯一來源），所以它精確等於「`on` 會改動的 key」——
  不是一份會默默落後的手挑清單。檔案裡有、但不在那份區塊裡的 key **不算**差異：
  `on` 只合併、從不移除（只有 `off` 會移除）。`copilot-here status` 顯示以 global default
  為基準的同類差異。若拒絕 `--fast` refresh，本 session 的 main 仍走 fast，但
  `settings.local.json` 位階較高，所以 pinned `ANTHROPIC_DEFAULT_*` role ids 不變。
- session 本身就是 `claude-copilot "$@"`，所以 specstory 自動存檔、`--no-specstory`、
  `-c`（繼續）的行為完全一致。`--fast` 等 wrapper flags 必須放在 Claude arguments 前；
  後面的 token 會被拒絕並顯示修正提示，避免吃掉 prompt 文字裡的 `--fast`。
- 結束時會提醒你代理還開著，以及怎麼 `copilot-proxy stop`。

### `copilot-run <cmd...>` —— 泛用環境變數注入器

`claude-copilot` 底下的積木：自動啟動代理，然後帶著代理 env 執行 *任意* 指令。
適合其他 Anthropic 相容工具或自訂的 specstory 呼叫：

注入的 env 區塊來自 `_copilot_env_json_for_model --live` —— 和 `copilot-here on` 寫入、
`_copilot_here_drift` 比對的是同一份 single source of truth，兩邊不可能再對「有哪些 key」
產生分歧。`--live` 是唯一差別：它用 `_copilot_client_base`（此刻這個 process 該連的位址）
解析 `ANTHROPIC_BASE_URL`，而不是設定檔會記錄的 pinned base。

```sh
copilot-run specstory run claude    # 等同 claude-copilot 做的事
copilot-run claude --resume         # 裸 claude，不經 specstory
```

### `codex-copilot [--no-specstory] [codex args...]` —— 一次性 Codex session

`codex-copilot` 與 `codex-copilot-once` 是完全相同、零持久化的 launcher。
它們會視需要啟動 gateway/shim，並用 CLI `-c` overrides 把自訂的
`copilot_api` Responses provider 傳給 Codex；不會編輯 `~/.codex/config.toml`
或 `.codex/config.toml`，所以 plain `codex` 仍走原本 provider。

Codex 預設走 `localhost:4142` shim。這一層除了限流與 measurement，也會正規化
Codex `mcp_list_tools` Responses item 裡的空白
description。MCP server 與原生 Codex path 可以省略描述，但 GitHub Copilot 會以
`Invalid 'input[0].tools[0].description': empty string` 拒絕請求。shim 只補這些
tool definition 欄位，不改 prompt、schema 或 tool name。
目前 Codex 會以 zstd 壓縮這些請求；shim 只解壓需要修補的 Responses body，改以
普通 JSON 轉送，並移除已不適用的 `content-encoding` header。
明確執行 `copilot-proxy shim off` 也會略過這個相容性修補與 metrics，因此只適合診斷逃生。

這是與 Claude Code `copilot-model --auto` 分開的 picker：後者保持
Claude-first，只有這個 Codex launcher 是 OpenAI-first。

- 呼叫者明確傳入 `-m` / `--model` 時永遠優先。否則使用與 `copilot-model` 相同的
  tier-aware policy，但 Codex 的 vendor 順序是 OpenAI/Codex、Claude、grok、Gemini、
  其他 chat model；embedding、disabled、picker-hidden 與 `-fast` main candidates 會排除。
- launcher 會把所選 model 的即時 context/prompt limit 傳給 Codex，並把
  `model_catalog_json` 指向 `codex debug models --bundled` 產生的版本化快取。
  Codex 的全域 `~/.codex/models_cache.json` 不會依 provider 分區；gateway refresh
  可能把 first-party entries 換成較小的 adapter subset，讓 `gpt-5.6-sol` 這類
  bundled model 出現 fallback-metadata warning。快取位於
  `$XDG_CACHE_HOME/copilot-proxy/codex-models/`（預設
  `~/.cache/copilot-proxy/codex-models/`），Codex 版本改變時會自動重建；呼叫者
  後續明確傳入的 `-c model_catalog_json=...` 仍優先。
- Claude/Gemini fallback 經 Responses Lite 轉譯；基本 tools、compaction、
  multi-agent orchestration 可用，但這條路不支援 Responses `tool_search`，因此
  auto 會把 native Responses OpenAI models 排在 Anthropic 前。
- Launcher 會啟用 gateway-backed remote compaction，並排除依賴不可用
  `tool_search` 的 `mcp__codex_apps__sites` namespace；使用者後續傳入的 `-c`
  仍可在單次呼叫覆寫這兩項。
- 有安裝 SpecStory 時預設執行 `specstory run codex`，並保留實際生效的
  `codex_cmd`（project config > user config > 裸 `codex`），再附加 provider、
  model 與使用者參數。Raw `--no-specstory` path 會自行維持同樣的
  `--ask-for-approval never --sandbox danger-full-access` posture；若使用者已指定
  approval/sandbox policy，則完全尊重該設定，不重複注入。

Codex 刻意不提供 `copilot-here` 對應物。官方 Codex config 允許 trusted project
使用 `.codex/config.toml`，但 project scope 會忽略 `model_provider`、
`model_providers`、provider auth 等 host-owned metadata。因此顯式 launcher 才能在
不改 user-wide default 的前提下，提供 project/session 邊界。參考
[configuration reference](https://developers.openai.com/codex/config-reference) 與
[configuration basics](https://developers.openai.com/codex/config-basic)。

#### 實驗性 direct provider（正式 helper 不使用）

以下設定會跳過 localhost；只有帳號 credential 能直接驗證到相符 Copilot endpoint
時才可用：

```toml
[model_providers.copilot-enterprise]
name = "GitHub Copilot Enterprise"
base_url = "https://api.enterprise.githubcopilot.com"
wire_api = "responses"
http_headers = { "Copilot-Integration-Id" = "vscode-chat", "Editor-Version" = "vscode/1.99.0", "Editor-Plugin-Version" = "copilot-chat/0.0.1", "User-Agent" = "GithubCopilot/1.0" }

[model_providers.copilot-enterprise.auth]
command = "gh"
args = ["auth", "token", "--hostname", "github.com"]
timeout_ms = 5000
refresh_interval_ms = 300000
```

這只是範例，不是受管設定。在本次 EMU/Enterprise 帳號實測，裸
`gh auth token` 對 enterprise API 回 `421 Misdirected Request`，而 Copilot token
exchange 回 `403`；`copilot-proxy auth` 保存的 token 經正常短效 Copilot token
exchange 則可用。Endpoint 也由 exchange 結果決定，hard-code personal/enterprise
host 不具可攜性。因此正式 helper 沿用已認證的 localhost gateway。

### `copilot-here [on|off|status]` —— 專案級持續開關

第二層：透過 `./.claude/settings.local.json` 把 **這個專案** 釘在代理上 ——
之後直接跑 `claude`（以及 `scode`/`svibe` 的窗格，它們就是跑
`specstory run claude`）都走代理，直到你關掉。需要 `jq`。

- `on` —— 用 jq 把代理的 `env` 區塊合併進 `settings.local.json`（不存在就建立），
  並確保 git 忽略該檔（寫入 `.git/info/exclude`；Claude Code 只會自動 gitignore
  *它自己* 建立的檔案）。會 commit 的 `.claude/settings.json`（`plansDirectory`
  等）完全不碰。
- `off` —— 只移除 `on` 加入的那些 env key；你自己放進 `settings.local.json`
  的其他內容會保留，檔案清空時才刪除。也會清掉 `~/.claude/settings.json` 中意外持久化的
  proxy-only 頂層 `model`，包含「local pin 本來就已經 off」的情況。
- `status` —— 有沒有釘選？base URL / 模型是什麼？代理沒在跑時會警告；接著列出唯讀的
  **plain Claude launch audit**：user/project/local settings、繼承的 model/base env，以及現在
  啟動會採用的 backend/model；也會列出仍在跑、必須重啟才會重讀磁碟設定的 Claude PID。
  若是 native Anthropic backend 搭配 proxy-only user model，會直接標出問題與清理指令。

### `copilot-model [<id>|-l|-L|-c|--auto|--why|--json]`

切換釘選的 Copilot 模型。需要 `jq`。寫入目標 —— 永遠不是會 commit 的
`.claude/settings.json`：

- 目前專案的 `copilot-here` 是 ON → 編輯 `./.claude/settings.local.json`。
- 否則 → 寫入全域狀態檔 `~/.local/state/copilot-proxy/model`，由
  `claude-copilot`、`copilot-run` 與下一次 `copilot-here on` 讀取。
  （`$COPILOT_CLAUDE_MODEL` 可覆寫狀態檔；最終預設是 `gpt-5.6-sol[1m]`。）

行為：

- 模糊 id：`copilot-model opus-4-8` 會解析成 `claude-opus-4-8`；點號寫法也會被
  正規化（`opus-4.8` 一樣可用）。
- `[1m]` 是只給 Claude Code 看的 context 提示。helper 會依 live `/v1/models`
  的 `max_context_window_tokens` 對每個 provider 自動決定，不再靠模型名寫死。
- Auto-compact 另外使用 `max_prompt_tokens`，透過
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` 設定真正的 prompt ceiling，再讓 Claude Code
  沿用約 95% 的預設觸發比例；不會硬塞固定 percentage。缺少明確 prompt limit 時才以
  context 減 maximum output 推導，`copilot-model -c` 會顯示結果。
- 會對照即時的代理 `/v1/models` 驗證（離線時仍提供靜態 discovery 清單供手動選擇）；
  打錯字與不明確的前綴會被拒絕，`--auto` 絕不從離線清單寫入 pin。
- `--auto` / `-a` 必須讀到 live catalog。先排除 policy-disabled、picker-hidden、
  embedding-only 與 `-fast` entries，再依 vendor 順序 Claude > OpenAI > grok > Gemini。
  同一 vendor 讀 Copilot 的 `model_picker_category`（`powerful > versatile > lightweight`），
  只在勝出的 tier 內比較世代。已知 id 與同世代 sibling 仍由 curated allowlist 決定；
  未知但更新世代的旗艦可以不等 dotfiles 更新就勝出。舊 proxy 沒有 category metadata
  時會退回既有 allowlist，不會猜測。Auto 也把目前明確 pin／persist 的 model 當作
  entitlement floor：候選的 `restricted_to` 集合不得更窄；沒有明確 baseline 時只考慮
  catalog 中最廣泛或 unrestricted 的 entries。手動指定 model 不受此限制。
- OpenAI 的世代與 capability tier 是兩個獨立維度：Astra 接替 Sol 的旗艦位置，Terra / Luna
  仍留在 5.6。因此 `gpt-6-astra` 高於 `gpt-5.6-sol`，但假想的輕量
  `gpt-6-luna` 不會。意圖依照 OpenAI 的
  [current model guidance](https://developers.openai.com/api/docs/guides/latest-model)。
  目前 Copilot catalog 只向 `pro_plus` / Business / Enterprise / Max 提供 Astra，context /
  prompt ceiling 為 1,000,000 / 872,000（比 Sol 的 1,050,000 / 922,000 小），且 reasoning
  從 `low` 起跳、沒有 `none`。向後相容的離線 fallback 仍是
  `gpt-5.6-sol[1m]`；這不代表 entitlement 較廣，請以 `copilot-model -L` 的 live
  PLANS 欄為準。`restricted_to` 只是 catalog 提示；`--auto` 無法證明目前 billing
  target／organization 的實際資格，若 inference 仍被 entitlement 拒絕，需手動改選其他
  served model。
- 無參數 → `fzf` 選單；`-c` 印出 main 來源與完整 role profile。`-l` 是可 pipe 的裸 id
  清單；`-L` / `--details` 顯示 live tier、price category、context/output limits、reasoning
  範圍、fast sibling、可用方案與 picker state；`*` 是目前模型，`->` 是具權威性的
  auto pick。Rows 為方便比較而按 tier／generation 分組，顯示順序不取代 vendor／allowlist policy。
- `--why` 只解釋而不寫入；`--auto --why` 先解釋再寫入。`--json` 原樣輸出 live
  `/v1/models`。它與 shim 的 `/_shim/fast-routing`、以及 Codex 專用的磁碟檔
  `~/.cache/copilot-proxy/codex-models/codex-cli_<version>.json` 是三種不同資料。
- 目前 OpenAI profile：Main/Fable/Opus = Astra（或手動指定的 main）、Sonnet = Terra、
  Haiku/background = Luna。缺少某層時退回 main，不會寫入未 served 的 id。Grok 不維護
  靜態版本 allowlist；使用其最高 tier 中最新的 served model。
- global state 仍是向後相容的單行 main id；wrapper 在啟動時依 live catalog 產生角色
  profile。Local pin 會寫入完整角色組。切換後只需重開 Claude Code，不用重啟 proxy。

建議順序：

```sh
copilot-proxy start
copilot-model --why        # 解釋自動選擇，不寫入
copilot-model -L            # 查看 live tier／price／context／plan metadata
copilot-model --auto        # 儲存 main／更新目前 project pin
copilot-model -c            # 檢查完整角色組
copilot-here on             # 黏著本專案，或改用 claude-copilot-once
```

`claude-copilot-once` 會暫時寫入同一組 profile，session 後還原。已存在的
`copilot-here` pin 仍會蓋過 shell env；用 `copilot-model --auto` 或 `copilot-here on`
更新它。

## 注入的 env（兩層設定的內容相同）

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:4141",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "gpt-5.6-sol[1m]",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "gpt-5.6-sol[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gpt-5.6-sol[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gpt-5.6-terra[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gpt-5.6-luna[1m]",
    "ANTHROPIC_SMALL_FAST_MODEL": "gpt-5.6-luna[1m]",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "922000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` 會被代理忽略，但必須設定。
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` 是所選模型的 provider prompt ceiling，不是完整
context size。以 1.05M context、128k maximum output 的 GPT 為例，實際 prompt ceiling
是 922k；`[1m]` 負責 HUD/full-window 分類，這個變數則確保 gateway 拒絕前先 compact。
若希望更早 compact，可自行設定 `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`。
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` 可減少背景流量（有助於速率限制）。
**不要** 把這段貼進會 commit 的 `.claude/settings.json` —— 改用 `copilot-here on`。

## Claude Code 功能相容性

關鍵分界是**本機編排 (local orchestration)** 與 **Anthropic cloud service**：

| 功能 | 透過 Copilot + GPT | 說明 |
|---|---|---|
| CLI、tools、hooks、skills、memory、plugins、MCP、checkpoints、sandboxing | 可以 | 這些是本機 Claude Code 功能；GPT 收到的是經過轉譯的 Claude prompt/tool schema，行為可能不完全一樣。 |
| subagents、dynamic workflows | 可以 | 不強制 `CLAUDE_CODE_SUBAGENT_MODEL`，保留 workflow/frontmatter 的 routing。[Workflow 文件](https://code.claude.com/docs/en/workflows) |
| `ultracode` | `2.3.4` 可以 | Ultracode 是 xhigh effort + dynamic workflows，不是單獨模型；2.3.4 會把 effort 傳到 GPT-5.6。 |
| thinking/reasoning | 轉譯後可用 | GPT 使用 Responses reasoning，不是 Anthropic-native thinking semantics。 |
| Fast inference | catalog 有提供時可用 | Codex `/fast` 由 shim 轉成 Copilot 的獨立 `-fast` sibling；Claude Code 使用 `claude-copilot --fast`。沒有 eligible sibling 時會警告並退回 standard。 |
| Web Search、auto mode、MCP tool search | 依 provider | 由 base-URL gateway 與 Copilot endpoint 能力決定；non-first-party tool search 可能需要額外 bridge/plugin。 |
| Ultrareview、Remote Control、Chrome、cloud Code Review、routines、web/mobile/Slack session | 不可以 | 這些需要 Claude.ai auth/cloud identity；local API gateway 無法取代。`ultrareview` 和 `ultracode` 無關。 |

官方參考：[feature availability](https://code.claude.com/docs/en/feature-availability)、
[model configuration](https://code.claude.com/docs/en/model-config)、
[gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)、
[Ultrareview](https://code.claude.com/docs/en/ultrareview)。

## 陷阱 (gotchas)（這些都花了實際 debug 時間）

### `start` used to hang at "Resolving dependencies" behind a socks proxy

（`start` 曾經卡在「Resolving dependencies」—— socks proxy 造成）

**已修正**（runner 啟動時不再解析套件），但仍值得理解，因為它的失敗樣態極具誤導性 ——
而且在有 proxy 的機器上，任何其他用 `bunx` 的工具都會踩到同一個坑。

`start` 以前跑的是 `bunx <pkg> start`，而 bunx **每次啟動都會重新解析套件**。
**bun 透過 socks `ALL_PROXY` 解析相依會無限期卡住** —— 但 `curl` 走同一個 proxy 連
registry 卻不到 0.5 秒就回來。所以每一項明顯的檢查都會過，沒有任何線索指向安裝程序。
你只會看到：

```
copilot-proxy: did not come up in time — check 'copilot-proxy logs'.
$ copilot-proxy logs
nohup: ignoring input
Resolving dependencies
```

有兩件事把「一次卡住」變成「永久卡死」：卡死的 `bun add` 會占住 bun 的**全域安裝快取鎖**，
所以下一次 `start` 也卡在那把鎖上；而 `start` 逾時後直接 return、沒有殺掉自己啟動的程序，
於是每重試一次就多留一個孤兒（實際上疊了 5 個），而且沒有任何一個綁上 port。

現在 runner 會把釘選的套件**只安裝一次**到 `~/.local/share/copilot-api/pkg` 並直接執行該
binary，所以熱啟動完全不碰網路。安裝本身有 timeout 且逾時會被殺掉，先退回「拿掉 proxy」
的重試；若 Bun 明確回 `UNKNOWN_CERTIFICATE_VERIFICATION_ERROR`，最後再改用 npm 的 CA stack。
TLS 驗證仍保持開啟，這是在繞過已觀察到的 Bun/Node CA-store 差異，不是關閉憑證檢查。
注意這裡的 registry 是 npmmirror（國內鏡像，為了 GFW 速度設在 `~/.bunfig.toml`）
—— 把它繞進 proxy 一點好處也沒有，而那正是弄壞 bun 的原因。

完整事後檢討與可 grep 的原始症狀：
[`pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md)。

### 模型清單只在啟動時抓一次 —— 直連被 geo-filter / 一次抓壞，整個 session 就毀了

`copilot-api` 只在**行程啟動時**向 GitHub 抓一次 `/models`，然後快取整個生命週期。
有兩種看起來一樣的壞法：

1. **Egress geo-filter（離開 TUN 後最常見）** — 同一組 token，直連／CN 出口 Claude = 0，
   走海外 Clash 節點 Claude = 8。Node / OpenCode **不讀** macOS System Proxy；以前
   Clash for Windows 的 TUN / Mixin 把所有 TCP 抓進去所以沒感覺，換成只有 System Proxy
   （Clash Verge）就會啟動成「沒有 Claude」的清單。預設 `COPILOT_HTTP_PROXY=auto` 會在
   偵測到本機 proxy 時自動帶 `--proxy-env`。
2. **節點抖一下** — 那一次請求碰上壞 hop，快取成截斷清單。

線索在啟動 banner：

```
ℹ Models refresh: 13 new     ← 壞掉：底下的清單裡沒有任何 claude id
ℹ Models refresh: 21 new     ← 正常
```

`copilot-proxy doctor` 會做 **直連 vs 走 proxy** 的上游 A/B，並對照代理已服務的清單，
避免再把 geo-filter 誤判成「組織停用 Claude」。完整說明：
[`pitfalls/copilot-api-caches-degraded-model-list-at-startup.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-api-caches-degraded-model-list-at-startup.md)。

### `settings.local.json` 的 env 蓋過 shell env（官方文件說法相反）

實測確認（2026-07）：目前版本的 Claude Code 會讓 `./.claude/settings.local.json` 的
`env` 區塊 **蓋過繼承而來的 shell 環境變數** —— 跟官方 settings 文件暗示的順序相反。
後果：

- `claude-copilot` / `copilot-run` **無法**改寫一個已經 `copilot-here on` 的專案
  （兩邊指向同一個代理時無害，指向不同時就會靜默地用錯設定）。
- 想透過 wrapper 試另一個代理／port，必須先 `copilot-here off`。

### OpenAI 模型思考時整條線是靜默的 —— shim 用心跳把 socket 撐住

`copilot-api` **不會**提早開啟 SSE stream：對 `:4141` 用 `gpt-5.6-sol` 實測，
response *headers* 在 8.11s 才到、第一個 body chunk 在 8.12s，也就是 reasoning
model 的整段思考時間都耗在同一個 `fetch()` 裡，線上一個 byte 都沒有。真正的
Anthropic stream 會用週期性的 `ping` event 蓋住這段，這個 gateway 一個都不送。
再加上 shim 的併發佇列（自適應範圍 4..8；超過當下 live limit 的請求會排隊），
路徑上任何一個 idle timer 都可以合法回收一條其實健康的連線。agent 這端
不會收到錯誤、只會一直等，最後只能 Esc + `continue`。

因此對「client 要求 streaming」的請求，shim 會在靜默達
`COPILOT_SHIM_PING_AFTER_MS` 後自己先 commit `text/event-stream` response，
並每 `COPILOT_SHIM_PING_MS` 送出 SSE *comment* frame
（`: copilot-shim keepalive`，符合規範的 parser 一律丟棄，所以對 Anthropic 與
OpenAI SDK 都是隱形的），直到真正的 bytes 出現 —— 排隊時間、思考時間、串流中途
的 reasoning 間隔都一併涵蓋。`COPILOT_SHIM_STALL_MS` 則替每次嘗試設上限：
headers 前卡死會 abort 並透明重試（此時 client 只收過 comment frame），
串流中途卡死則以真正的錯誤結束回應，而不是無限等待。

| Env | 預設 | 意義 |
|---|---|---|
| `COPILOT_SHIM_MIN` | `4` | 自適應並行 floor，也是啟動 limit |
| `COPILOT_SHIM_MAX` | `8` | 自適應 ceiling；設成與 `MIN` 相同即可固定上限 |
| `COPILOT_SHIM_PING_MS` | `15000` | 心跳間隔；`0` 關閉 |
| `COPILOT_SHIM_PING_AFTER_MS` | `10000` | 提早 commit SSE 前容忍的靜默時間 |
| `COPILOT_SHIM_STALL_MS` | `240000` | 判定上游卡死的靜默時間；`0` 關閉 |

快速 non-2xx 回應保留真正的 status code 與 headers，因此
`400 model_not_supported`、`401 IDE token expired` 仍能正確回報。對 `stream:true`
的快速 HTTP 2xx，只有 SSE media type 才會接受；headers 尚未 commit 時，shim 仍可直接
拒絕 protocol mismatch。SSE response 一旦 commit，之後才出現的 non-2xx 只能以
protocol-native terminal event 送出，所以不要把 `COPILOT_SHIM_PING_AFTER_MS` 調成 0。

對 `/responses`，shim 也會驗證上游 SSE 最後是否到達
`response.completed`、`response.failed` 或 `response.incomplete`。在這些 terminal event
之前就 EOF，會記成 `upstream_protocol_eof`，不再算成功。這只改善診斷；shim 絕不偽造
完成事件。若 fork log 同時出現 `WebSocket error`，請把 data dir `config.json` 裡的
`useResponsesApiWebSocket` 設成 `false` 後 restart；fork 的 WebSocket 失敗不會自動
fallback 到 HTTP。0ms stream 的指紋與已驗證 A/B 步驟見
[`pitfalls/copilot-responses-stream-closed-before-completed.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-responses-stream-closed-before-completed.md)。

FleetView 顯示 `0 tok` **不是**這個 bug 的證據 —— 那個計數器只在 agent 結束時才
回填。先去看 `agent-<id>.jsonl` 的 `assistant` 筆數有沒有在長。完整診斷：
[`pitfalls/copilot-proxy-openai-model-silent-stall.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-openai-model-silent-stall.md)。

### Fast mode 是 catalog model route，不是轉送 Copilot tier

OpenAI Responses API 以 `service_tier="fast"`（歷史上也用 `priority`）表示 Fast Mode；
目前釘選的 Copilot fork 會移除這個欄位，而 GitHub Copilot 則把 fast inference
advertise 成另一個 model id，例如 eligible 的 `<standard>-fast` sibling。前置 shim
現在會銜接這兩種表示法：每五分鐘由 live `/v1/models` catalog 推導 standard-to-fast
pair，把 Codex `/fast` request 改寫到 sibling，再於 fork 收到前移除不支援的 tier。
參考 OpenAI [Fast Mode guide](https://developers.openai.com/api/docs/guides/fast-mode)。

Claude Code 原生 `/fast` 在這個 custom Anthropic gateway 仍不可用，因此要使用
`claude-copilot --fast`（也可經 `claude-copilot-once` 傳入）。Wrapper 會用 session-only
`--model` override 選同一份 live-catalog sibling。Discovery 失敗時保留 last-good cache；
完全沒有 eligible sibling 時，兩條路徑都退回 standard model 並送出去重警告。
`copilot-proxy status` 與 `doctor` 會顯示 routing state；明確執行
`copilot-proxy shim off` 也會關掉這項轉譯。不會為了測試 Fast 可用性自動送出會消耗
quota 的 inference probe。

### 舊版 shim 會卡住 port，而不是被換掉

`_copilot_shim_alive` 探測的是 `/_shim/health` 而不是單純連得上，這樣任意程序 ——
或**舊版本的 shim** —— 才不會被誤認成健康的 metrics shim。但舊版 shim 會把這個路徑
轉發到上游，於是 `:4141` 回 `404`，探測正確地判定「死了」，而作業系統仍然認為
「port 被佔用」。過去啟動流程把「死了」當成「port 是空的」，spawn 出來的程序立刻
`EADDRINUSE` 死掉，結果每個 managed launcher 都對著一個其實正在跑的 shim fail closed。

現在 `_copilot_shim_start` 直接讀 port（`lsof -tiTCP -sTCP:LISTEN`）：command line 命中
`copilot-throttle-shim.js` 的就是我們自己的，直接回收；其他一律印出 PID 與 command 後
拒絕啟動 —— 在一個眾所周知的 port 上砍掉無關程序不是它該做的決定，要讓路請改用
`COPILOT_SHIM_PORT`。判讀特徵是**代理**的 log 裡一整片 `GET /_shim/health 404`
（[pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-shim-eaddrinuse-stale-build.md)）。

### fork 沒有速率限制器

fork 的 `start` 拿掉了 `--rate-limit`/`--wait`。它 README 給的緩解方式是改成減少
Claude Code 的背景雜訊 —— 那正是 `COPILOT_PROXY_QUIET=1` 注入的東西（這裡預設關閉；
我們優先保 UX 而不是 Copilot quota）。前置 shim 現在提供並行 admission 與 transient
retry，但它不是按時間間隔限制請求的 rate limiter。真的需要後者時，退回原始套件：
`COPILOT_API_PKG=copilot-api@0.7.0`。

### Context management 是轉譯，不是 Anthropic-native

舊 fork 可能把 Claude Code 的 `context_management` 原樣送到會回 400 的 endpoint
（[caozhiyuan#305](https://github.com/caozhiyuan/copilot-api/issues/305)）。目前釘選的 `2.3.4` 的
GPT-5.6 path 會壓掉這個不相容欄位，改依 Responses reasoning/context handling。這避開 400，
但不會完整重現 Anthropic 的 context editing 與 prompt-cache semantics；長 session 仍需觀察。

### 不要使用 Claude Code 內建的 `/model` 選單

這裡其實有兩個不同陷阱：

1. 按 **Enter** 代表「設為預設」，不是「只用於本 session」（後者是 `s`）。Claude Code
   會把 custom proxy id 寫入 `~/.claude/settings.json` 的頂層 `model`。沒有 guard 時，之後
   即使 `copilot-here off`、也沒有 `ANTHROPIC_*` env，`specstory run claude` 仍會顯示
   GPT/Terra/Luna。
2. 選內建 Anthropic 項目時可能送出 *官方* 帶日期 id（例如
   `claude-opus-4-8-YYYYMMDD`），會被 Copilot 後端拒絕：

```
API Error: 400 {"error":{"message":"The requested model is not supported.",
"code":"model_not_supported", ...}}
```

改用 `copilot-model` 釘選代理模型 —— 不帶日期的連字號 id（`claude-opus-4-8`）可以正常
運作，只有選單送出的帶日期 id 會失敗。不用啟動 Claude Code，也可以用
`copilot-here status` 看目前各層與實際生效的 backend/model。

### 點號 id 會造成「Opus 4 retired」警告與 >100% 的 context HUD

歷史陷阱，已由連字號預設值修掉。使用 **點號** id（`claude-opus-4.8`，也就是舊版原始代理
唯一接受的形狀）時，Claude Code 無法對應到它內建的模型表，於是：

- 顯示 `[Opus 4]` 並警告 *"Claude Opus 4 was retired"*（退回最接近的、已退役的名稱），且
- 假設 context window 是 **200k**，但 Copilot 實際上以 **1M** 提供 opus-5 / opus-4-8 /
  sonnet-5（`/v1/models` 裡的 `max_context_window_tokens: 1000000`）—— 所以 HUD/statusline
  的 context 可能顯示超過 100%，compaction 也會用錯誤的預算觸發。

helper 會使用連字號 id，並依每個 live model 的 context metadata 自動加 `[1m]`；GPT id 也適用，
例如 `gpt-5.6-sol[1m]`。此外會從 `max_prompt_tokens` 獨立設定精確的 auto-compact capacity；
`[1m]` 本身不是精確的 prompt limit。Claude Code 送出前會剝掉 suffix；raw API client 必須使用
plain id。

### Token 陷阱：`gho_` vs `ghu_`

有兩個不同的 GitHub token，且 **不可** 互換：

| 來源 | 前綴 | `copilot_internal/v2/token` 交換 |
|---|---|---|
| OpenCode 儲存的 auth | `gho_` | **失敗 (404)** |
| `copilot-proxy auth`（裝置登入） | `ghu_` | **成功** |

OpenCode 的 `gho_` token（OAuth App）只有在 *直接* 當 Bearer 打 `api.githubcopilot.com`
時能用；它無法完成 copilot-api 的傳統 token 交換步驟。**讓 `copilot-proxy auth` 產生它自己的
`ghu_` token —— 不要重用 OpenCode 的。** Token 儲存在
`~/.local/share/copilot-api/github_token`。

## 可用模型與角色 discovery

以 `GET /v1/models` 為 live truth：GitHub 會依帳號、組織政策、rollout 與 egress 改變 catalog。
Claude Code 現在有 Fable、Opus、Sonnet、Haiku 角色；`copilot-model --auto` 只會映射 catalog
裡實際存在的 id。`copilot-model -l` 顯示 raw served ids，`copilot-model -c` 顯示生效中的
角色 profile。不要複製帶日期的 Anthropic id，也不要手猜哪些模型有 1M context。

## 實用指令

```sh
claude-copilot                       # 一次性代理 session（specstory 包裝）
claude-copilot-once                  # 透過 settings.local.json pin 跑一次 session（自動還原）
copilot-here status                  # 這個專案有釘在代理上嗎？
copilot-model -c                     # 目前模型 + 來自哪一層
copilot-proxy status                 # 有沒有在跑？提供哪些 Claude 模型？
copilot-proxy limiter status         # live limit / active / queued
copilot-proxy limiter set --limit 6  # 暫時調整，不重啟或中斷 stream
copilot-proxy whoami                 # 驗證 token → 帳號 / plan / quota
copilot-proxy logs 60                # tail 代理的 log
copilot-proxy logs -f 60             # 跨 restart / rotation 持續 follow
copilot-proxy logs shim -f            # follow limiter 與 keepalive 事件
# 用量儀表板 (dashboard)（fork 已在本地內建）：
#   http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

## 參見

- [Copilot embeddings → 語意搜尋](copilot-embeddings.zh-TW.md) —— 同一個 proxy 的
  `/v1/embeddings` 端點，接成 `copilot-embed` + `semsearch`（本機語意搜尋）
- [Raycast AI 自帶模型 (BYOK) → 本機 Copilot 代理 (proxy)](raycast-ai-byok.zh-TW.md)
  —— 同一個 proxy 接進 Raycast 的 Quick AI / AI Chat / AI Commands（`copilot-raycast`），
  以及那個分辨「真的能用」與「`/v1/models` 只是宣稱有」的零額度探針
- [copilot-api](https://github.com/ericc-ch/copilot-api) —— 代理本體
- [Copilot agent gateway 指令](../shells/aliases.md#copilot-agent-gateway)
- [Claude Code 設定優先序](https://code.claude.com/docs/en/settings) —— 為什麼
  `settings.local.json` / 環境變數才是正確的注入層
- [Agent overlays](agent-overlays.md) —— 本設計刻意避開的
  chezmoi 管理 `~/.claude/settings.json`
- OpenCode 原生的 GitHub Copilot provider（OpenCode 本身不需要代理）
