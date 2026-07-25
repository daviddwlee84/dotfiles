# Copilot → Claude Code 代理 (proxy)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

用 **GitHub Copilot** 訂閱裡的 Claude 模型來驅動
[Claude Code](https://docs.anthropic.com/en/docs/claude-code)，透過本機的逆向工程
(reverse-engineered) 代理 (proxy)
[`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api)。

- **Shell helpers**：`~/.config/shell/43_copilot_proxy.sh`（`copilot-proxy`、`claude-copilot`、`copilot-run`、`copilot-here`、`copilot-model`）
- **執行器 (runner)**：`@jeffreycao/copilot-api`（已釘選 pinned），**只安裝一次**到
  `~/.local/share/copilot-api/pkg`，之後直接執行該處的 binary。刻意**不**在啟動時用
  `bunx`：bunx 每次啟動都會重新解析套件，而 bun 透過 socks `ALL_PROXY` 解析相依會永遠卡住
  —— 詳見[陷阱](#start-used-to-hang-at-resolving-dependencies-behind-a-socks-proxy)。
  熱啟動 (warm start) 在綁定 port 之前完全不碰網路。
- **不由 ansible 安裝** —— 在第一次 `copilot-proxy start` 時安裝，因此不進佈建
  (provisioning) 流程。要強制重裝：`copilot-proxy reinstall`（改版號會自動重裝）。

!!! warning "這違反 GitHub Copilot 的服務條款 (Terms of Service)"
    用 Copilot 訂閱去驅動非 GitHub 的 agent 是不被允許的，且 copilot-api 是逆向工程/非官方
    的。copilot-api 自己的 README 就警告它可能觸發 GitHub 的 **濫用偵測 (abuse detection)**，
    導致 **Copilot 存取被暫時停權 (temporary suspension)**。Claude Code 很吃 token（頻繁的背景
    請求、大 context），務必搭配速率限制 (rate limit) 使用。風險自負；建議用個人帳號而非公司席位
    (corporate seat)。

## 快速開始

```sh
copilot-proxy auth      # 一次性：GitHub 裝置登入 (device login)（儲存 ghu_ token）

claude-copilot          # 一次性 session 走代理（自動啟動代理；不寫任何檔案）
claude-copilot-once     # 釘住「這個專案」跑一次 session，結束自動解除（代理需已啟動）

copilot-here on         # 或者：釘選「這個專案」—— 之後直接跑 `claude` 就走代理
copilot-here off        # 取消釘選 —— 回到真正的 Anthropic 後端
```

## 運作原理

```
Claude Code ──Anthropic /v1/messages──▶ copilot-api (localhost:4141)
                                          │ 在 Anthropic <-> Copilot 之間轉譯
                                          │ Authorization: Bearer <copilot token>
                                          ▼
                                   api.githubcopilot.com  （你的 Copilot 訂閱）
```

- Claude Code 只講 **Anthropic Messages API**（`/v1/messages`）。
- Copilot 的 chat 端點是 **OpenAI 相容 (compatible)** 的（`/chat/completions`）。
- copilot-api 在兩者之間轉譯並注入 Copilot 的認證 (auth)。
- Claude Code 透過 `ANTHROPIC_BASE_URL` 被指向代理 —— 注入方式有兩種：
  per-process 環境變數（`claude-copilot`），或 gitignore 掉的
  `./.claude/settings.local.json`（`copilot-here on`）。見「設定分層設計」。

## 設定分層設計（代理設定該放哪一層、為什麼）

Claude Code 由低到高合併設定：`~/.claude/settings.json`（user）→
`./.claude/settings.json`（project，會 commit）→ `./.claude/settings.local.json`
（local，gitignored）→ CLI flags —— 且 **shell 環境變數蓋過所有 settings 檔的
`env` 區塊**（[官方文件](https://code.claude.com/docs/en/settings)）。

其中兩層已有其他工具負責，必須保持乾淨：

| 層 | 擁有者 | 為什麼代理設定「不能」放這裡 |
|---|---|---|
| `~/.claude/settings.json` | chezmoi（`dot_claude/modify_settings.json.tmpl`） | 會讓 *每個* 專案永遠走代理；還會跟 chezmoi 的合併打架 |
| `./.claude/settings.json` | `claude-plans-here`（`plansDirectory`） | 會 commit 進 git —— 代理設定會外洩給整個團隊 |

所以代理使用沒人佔用的兩層：

| 啟用 | 機制 | 範圍 | 停用 |
|---|---|---|---|
| `claude-copilot` / `copilot-run` | per-process 環境變數 | 單一 session | 下次直接跑 `claude` 即可 |
| `copilot-here on` | `./.claude/settings.local.json`（gitignored） | 這個專案、持續生效 | `copilot-here off` |

```
~/.claude/settings.json          .claude/settings.json         .claude/settings.local.json      shell env
(chezmoi: hooks/plugins)    <    (git: plansDirectory)     <   (copilot-here on/off)        <   (claude-copilot)
```

## Shell helpers

### `copilot-proxy [start|stop|restart|status|doctor [--live]|logs [N]|whoami|auth]`

在 `$COPILOT_PROXY_PORT`（預設 `4141`）管理背景代理。

| 環境變數 | 預設 | 意義 |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | 代理監聽的 port |
| `COPILOT_PROXY_RATE` | `15` | `--rate-limit` 秒數（節流；請溫和） |
| `COPILOT_API_PKG` | `copilot-api@0.7.0` | 要安裝的套件規格（釘選/升級）。改了會自動重裝。 |
| `COPILOT_INSTALL_NOPROXY` | `0` | `1` = 安裝時把 proxy 環境變數拿掉，跳過「bun 無法透過 proxy 解析」那 45 秒的卡頓 |

這些設在 `~/.shellrc.adhoc`（或 per-shell secrets 檔案）。在 `copilot-proxy auth`
儲存 token 之前，`start` 會拒絕執行；啟動後最多等 ~20 秒直到代理能回應才返回。

**第一次** `start` 會把釘選的套件安裝到 `~/.local/share/copilot-api/pkg`（並寫下 spec
戳記），之後每次啟動只是直接執行那個 binary —— 不打 registry、不做啟動時解析。安裝時會
先用你當下的環境變數（在「registry 只能透過 proxy 連到」的機器上必要），卡住就改用拿掉
proxy 的重試；兩種嘗試都有 timeout 並會被殺掉，所以卡死的安裝再也不可能占住 bun 的全域
快取鎖而拖垮下一次。`start` 逾時的時候現在也會**把自己啟動的 server 殺掉**，不會像以前
那樣每重試一次就留下一個孤兒程序。

`copilot-proxy whoami` 是真正的登入檢查：它拿儲存的 token 對 GitHub 交換，並印出你的
帳號 / plan / quota（token 缺失或過期時會明確報錯）。用它取代直接看 token 檔案 —— token
是明文憑證 (plaintext credential)，不應在編輯器裡打開。

### `copilot-proxy doctor [--live]`（別名：`test`）

診斷整條路徑，任何一項失敗就以非零狀態結束。預設**唯讀**；加上 `--live` 會多送一個真實的
`POST /v1/messages`（`max_tokens: 1`、挑一個非 `[1m]` 的 chat model），會消耗一個 quota
單位，但那是唯一能驗證 streaming 的檢查。

檢查順序：前置工具（`bun`/`curl`/`jq`）→ **套件 (package)** → token 檔案 → 代理與
throttle shim 是否存活 → 安裝殘留（stale installer）→ **模型**→ 上游連線 →
本機代理 / VPN → live probe。

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

它同時會拿**釘選的**模型（`copilot-model -c` 的實際生效值，會尊重 `copilot-here` 的專案
釘選）去比對已提供的清單 —— 包含 `copilot-model -l` **不會**顯示的 `[1m]` 別名。釘選了一個
沒被提供的 id，代表每一個請求都會 400。

上游連線會同時探測 `api.enterprise.githubcopilot.com` 與 `api.githubcopilot.com`，直連
**以及**（若有設定）走 macOS 系統代理，所以 Clash/mihomo 規則黑洞掉其中一個 host 時會立刻
顯現。未帶認證的 `400`/`401` 算「連得到」—— 只有連線/讀取失敗才算故障。`doctor` 絕不會印出你的
token：憑證是透過 `curl -K -`（stdin）傳入，而非 argv，因為 argv 可被 `ps` 讀到。

### `claude-copilot [--no-specstory] [claude args...]` —— 一次性 session

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
  `--no-specstory` 刻意不繼承（既然退出 specstory，就一併退出它的設定）。
- 還原 = 不用還原；下次直接跑 `claude` 完全不受影響。

### `claude-copilot-once [--no-specstory] [claude args...]` —— 一次性釘選 session

第一層的用完即丟 + 第二層的可靠度：用 `copilot-here on` 釘住 **這個專案**，跑一個
`claude-copilot` session，結束時 `copilot-here off` —— 連 Ctrl-C 也會還原。當純環境變數
注入不夠力（因為 `settings.local.json` 位階高於 shell env，見陷阱章節）、但你又不想留下
一個黏著的 pin 時就用它。

- **前提條件：** 代理必須**已經**在跑 —— 跟 `claude-copilot` 不同，它**不會**自動啟動；
  代理沒回應時它只印出 `copilot-proxy start` 提示並回傳非零。
- **不動既有 pin：** 如果這個專案的 `copilot-here` 本來就是 `on`，結束時會原樣保留
  （不會去解除你沒要求解除的 pin）。如果那個 pin **過期了** —— 跟現在 `copilot-here on`
  會寫入的內容不一致，例如預設值已經移到 `claude-opus-5[1m]` 而 pin 還停在
  `claude-opus-4-8[1m]`，或是 pin 建立時某個 key 還不存在 —— 它會印出差異，並詢問要
  就地更新（`copilot-here on`）還是保留。預設答案是**保留**（stdin 非互動時自動保留）。
  差異的計算方式是拿現檔去 diff `copilot-here on` 會合併的那份 env 區塊
  （`_copilot_env_json`，兩邊共用的唯一來源），所以它精確等於「`on` 會改動的 key」——
  不是一份會默默落後的手挑清單。檔案裡有、但不在那份區塊裡的 key **不算**差異：
  `on` 只合併、從不移除（只有 `off` 會移除）。`copilot-here status` 會印出同一份差異報告。
- session 本身就是 `claude-copilot "$@"`，所以 specstory 自動存檔、`--no-specstory`、
  `-c`（繼續）的行為完全一致。
- 結束時會提醒你代理還開著，以及怎麼 `copilot-proxy stop`。

### `copilot-run <cmd...>` —— 泛用環境變數注入器

`claude-copilot` 底下的積木：自動啟動代理，然後帶著代理 env 執行 *任意* 指令。
適合其他 Anthropic 相容工具或自訂的 specstory 呼叫：

```sh
copilot-run specstory run claude    # 等同 claude-copilot 做的事
copilot-run claude --resume         # 裸 claude，不經 specstory
```

### `copilot-here [on|off|status]` —— 專案級持續開關

第二層：透過 `./.claude/settings.local.json` 把 **這個專案** 釘在代理上 ——
之後直接跑 `claude`（以及 `scode`/`svibe` 的窗格，它們就是跑
`specstory run claude`）都走代理，直到你關掉。需要 `jq`。

- `on` —— 用 jq 把代理的 `env` 區塊合併進 `settings.local.json`（不存在就建立），
  並確保 git 忽略該檔（寫入 `.git/info/exclude`；Claude Code 只會自動 gitignore
  *它自己* 建立的檔案）。會 commit 的 `.claude/settings.json`（`plansDirectory`
  等）完全不碰。
- `off` —— 只移除 `on` 加入的那些 env key；你自己放進 `settings.local.json`
  的其他內容會保留，檔案清空時才刪除。
- `status` —— 有沒有釘選？base URL / 模型是什麼？代理沒在跑時會警告。

### `copilot-model [<id>|-l|-c]`

切換釘選的 Copilot 模型。需要 `jq`。寫入目標 —— 永遠不是會 commit 的
`.claude/settings.json`：

- 目前專案的 `copilot-here` 是 ON → 編輯 `./.claude/settings.local.json`。
- 否則 → 寫入全域狀態檔 `~/.local/state/copilot-proxy/model`，由
  `claude-copilot`、`copilot-run` 與下一次 `copilot-here on` 讀取。
  （`$COPILOT_CLAUDE_MODEL` 可覆寫狀態檔；最終預設是 `claude-opus-5[1m]`。）

行為：

- 模糊 id：`copilot-model opus-4-8` 會解析成 `claude-opus-4-8`；點號寫法也會被
  正規化（`opus-4.8` 一樣可用）。
- `[1m]` 後綴（`copilot-model 'opus-4-8[1m]'`）驗證時會被剝掉、之後再接回去 ——
  它是只給 Claude Code 看的 1M context 提示，詳見下方模型 id 章節。
- 會對照即時的代理 `/v1/models` 驗證（代理未啟動時退回靜態 Claude 清單）；打錯字與不明確的
  前綴會被拒絕。
- 無參數 → `fzf` 選單。`-c` 印出目前模型以及它來自哪一層。
- 同時寫入 `ANTHROPIC_MODEL` 與 `ANTHROPIC_DEFAULT_OPUS_MODEL` ——
  **變更只在下次 `claude` 啟動時生效**（env 在啟動時讀取）。切換模型 **不需要** 重啟代理。

## 注入的 env（兩層設定的內容相同）

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:4141",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "claude-opus-5[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` 會被代理忽略，但必須設定。
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` 可減少背景流量（有助於速率限制）。
**不要** 把這段貼進會 commit 的 `.claude/settings.json` —— 改用 `copilot-here on`。

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
binary，所以熱啟動完全不碰網路。安裝本身有 timeout 且逾時會被殺掉，並會退回「拿掉 proxy」
的重試。注意這裡的 registry 是 npmmirror（國內鏡像，為了 GFW 速度設在 `~/.bunfig.toml`）
—— 把它繞進 proxy 一點好處也沒有，而那正是弄壞 bun 的原因。

完整事後檢討與可 grep 的原始症狀：
[`pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-proxy-start-hangs-at-resolving-dependencies.md)。

### 模型清單只在啟動時抓一次 —— 一次抓壞，整個 session 就毀了

`copilot-api` 只在**行程啟動時**向 GitHub 抓一次 `/models`，然後快取整個生命週期，
不會定期更新、也不會在 cache miss 時重抓。若那一次請求剛好碰上 VPN / Clash 節點不穩，
代理就會帶著一份**被截斷的清單**啟動 —— 通常只剩非 Anthropic 的模型 —— 之後每個
`claude-*` 請求都會回 `400 model_not_supported`，直到你重啟為止。

線索在啟動 banner：

```
ℹ Models refresh: 13 new     ← 壞掉：底下的清單裡沒有任何 claude id
ℹ Models refresh: 21 new     ← 正常
```

log 裡沒有任何其他線索能把這個情況跟「我的組織停用了 Claude」區分開 —— 兩者產生的
GitHub 400 一模一樣。`copilot-proxy doctor` 會把代理的快取清單跟即時上游清單相比對，
直接告訴你是哪一種。若是快取問題，修法就只是 `copilot-proxy restart`。完整說明：
[`pitfalls/copilot-api-caches-degraded-model-list-at-startup.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/copilot-api-caches-degraded-model-list-at-startup.md)。

### `settings.local.json` 的 env 蓋過 shell env（官方文件說法相反）

實測確認（2026-07）：目前版本的 Claude Code 會讓 `./.claude/settings.local.json` 的
`env` 區塊 **蓋過繼承而來的 shell 環境變數** —— 跟官方 settings 文件暗示的順序相反。
後果：

- `claude-copilot` / `copilot-run` **無法**改寫一個已經 `copilot-here on` 的專案
  （兩邊指向同一個代理時無害，指向不同時就會靜默地用錯設定）。
- 想透過 wrapper 試另一個代理／port，必須先 `copilot-here off`。

### fork 沒有速率限制器

fork 的 `start` 拿掉了 `--rate-limit`/`--wait`。它 README 給的緩解方式是改成減少
Claude Code 的背景雜訊 —— 那正是 `COPILOT_PROXY_QUIET=1` 注入的東西（這裡預設關閉；
我們優先保 UX 而不是 Copilot quota）。真的需要請求節流的話，退回原始套件：
`COPILOT_API_PKG=copilot-api@0.7.0`。

### fork 的小毛病：`context_management` 可能 400

較新的 Claude Code context-editing 可能會塞入 `context_management`，而 Copilot 原生的
`/v1/messages` endpoint 會以 400 拒絕
（[caozhiyuan#305](https://github.com/caozhiyuan/copilot-api/issues/305)，與版本有關）。
實際測試中真實的 Claude Code 執行沒有觸發到，但如果你在長 session 看到無法解釋的 400，
先去看那個 issue。

### 不要使用 Claude Code 內建的 `/model` 選單

它送出的是 Anthropic 的 *官方* 帶日期 id（例如 `claude-opus-4-8-YYYYMMDD`），會被 Copilot
後端拒絕：

```
API Error: 400 {"error":{"message":"The requested model is not supported.",
"code":"model_not_supported", ...}}
```

改用 `copilot-model` 釘選模型 —— 不帶日期的連字號 id（`claude-opus-4-8`）可以正常運作，
只有選單送出的帶日期 id 會失敗。

### 點號 id 會造成「Opus 4 retired」警告與 >100% 的 context HUD

歷史陷阱，已由連字號預設值修掉。使用 **點號** id（`claude-opus-4.8`，也就是舊版原始代理
唯一接受的形狀）時，Claude Code 無法對應到它內建的模型表，於是：

- 顯示 `[Opus 4]` 並警告 *"Claude Opus 4 was retired"*（退回最接近的、已退役的名稱），且
- 假設 context window 是 **200k**，但 Copilot 實際上以 **1M** 提供 opus-5 / opus-4-8 /
  sonnet-5（`/v1/models` 裡的 `max_context_window_tokens: 1000000`）—— 所以 HUD/statusline
  的 context 可能顯示超過 100%，compaction 也會用錯誤的預算觸發。

正確做法就是目前 helper 預設注入的 id 形狀：**`claude-opus-5[1m]`** —— 連字號讓 Claude Code
認得這個 family（顯示名稱正確、沒有退役警告），`[1m]` 後綴讓它把 context 算成 1M。
Claude Code 送出前會把 `[1m]` 剝掉，所以代理收到的是合法 id（在原生 API 呼叫裡放**字面上**
的 `...[1m]` 會被拒絕 —— `copilot-model` 驗證時會自行處理剝除）。

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

## 可用的 Claude 模型 id

經 `/v1/models` + `/v1/messages` 驗證（2026-07）：`claude-opus-4-5`、`claude-opus-4-6`、
`claude-opus-4-7`、`claude-opus-4-8`、`claude-opus-5`、`claude-sonnet-4-5`、
`claude-sonnet-4-6`、`claude-sonnet-5`、`claude-haiku-4-5`。fork 在請求時連字號與舊的點號
形式（`claude-opus-4.8`）都收，但**在 Claude Code 裡請用連字號 id** —— 點號會破壞它的
模型辨識（見陷阱章節）。`/v1/models` capabilities 回報的 context window：opus-5、opus-4-8
與 sonnet-5 是 **1M**（`max_prompt_tokens: 936000`），haiku-4-5 是 200k —— 對 1M 的模型
請補上 `[1m]` 後綴讓 Claude Code 知道。非 Claude 模型（gpt-5.5、gemini-3.1-pro-preview…）
也有提供 —— 見 `copilot-model -l` 或 `GET /v1/models`。

## 實用指令

```sh
claude-copilot                       # 一次性代理 session（specstory 包裝）
claude-copilot-once                  # 透過 settings.local.json pin 跑一次 session（自動還原）
copilot-here status                  # 這個專案有釘在代理上嗎？
copilot-model -c                     # 目前模型 + 來自哪一層
copilot-proxy status                 # 有沒有在跑？提供哪些 Claude 模型？
copilot-proxy whoami                 # 驗證 token → 帳號 / plan / quota
copilot-proxy logs 60                # tail 代理的 log
# 用量儀表板 (dashboard)（fork 已在本地內建）：
#   http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

## 參見

- [Copilot embeddings → 語意搜尋](copilot-embeddings.zh-TW.md) —— 同一個 proxy 的
  `/v1/embeddings` 端點，接成 `copilot-embed` + `semsearch`（本機語意搜尋）
- [copilot-api](https://github.com/ericc-ch/copilot-api) —— 代理本體
- [`bunx` CLI aliases](../shells/aliases.md#copilot--claude-code-代理-proxy)
- [Claude Code 設定優先序](https://code.claude.com/docs/en/settings) —— 為什麼
  `settings.local.json` / 環境變數才是正確的注入層
- [Agent overlays](agent-overlays.md) —— 本設計刻意避開的
  chezmoi 管理 `~/.claude/settings.json`
- OpenCode 原生的 GitHub Copilot provider（OpenCode 本身不需要代理）
