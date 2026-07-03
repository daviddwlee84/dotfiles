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
- **執行器 (runner)**：`bunx copilot-api`（已釘選 pinned；沿用 `07_bunx_cli.sh` 的 `bunx` 慣例）
- **不由 ansible 安裝** —— 透過 `bunx` 隨用隨拉，因此不進佈建 (provisioning) 流程。

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
| `~/.claude/settings.json` | chezmoi（`dot_claude/modify_settings.json`） | 會讓 *每個* 專案永遠走代理；還會跟 chezmoi 的合併打架 |
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

### `copilot-proxy [start|stop|restart|status|logs [N]|whoami|auth]`

在 `$COPILOT_PROXY_PORT`（預設 `4141`）管理背景代理。

| 環境變數 | 預設 | 意義 |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | 代理監聽的 port |
| `COPILOT_PROXY_RATE` | `15` | `--rate-limit` 秒數（節流；請溫和） |
| `COPILOT_API_PKG` | `copilot-api@0.7.0` | `bunx` 套件規格（釘選/升級） |

這些設在 `~/.shellrc.adhoc`（或 per-shell secrets 檔案）。在 `copilot-proxy auth`
儲存 token 之前，`start` 會拒絕執行；啟動後最多等 ~20 秒直到代理能回應才返回。

`copilot-proxy whoami` 是真正的登入檢查：它拿儲存的 token 對 GitHub 交換，並印出你的
帳號 / plan / quota（token 缺失或過期時會明確報錯）。用它取代直接看 token 檔案 —— token
是明文憑證 (plaintext credential)，不應在編輯器裡打開。

### `claude-copilot [--no-specstory] [claude args...]` —— 一次性 session

第一層：跑一次走代理的 Claude Code session，**完全不寫檔案**。代理沒回應時會自動
啟動它，然後以 per-process 的 `ANTHROPIC_*` 環境變數啟動 `claude`（shell 環境變數
蓋過所有 settings 檔的 `env` 區塊，所以即使專案沒開 `copilot-here` 也會生效）。

- 有安裝 specstory 時自動包成 `specstory run claude`（markdown 自動存檔 ——
  跟 `scode`/`svibe` 同一套慣例）；用 `--no-specstory` 退出。額外參數透過
  specstory 的 `-c "custom command"` 傳給 claude CLI：`claude-copilot -c`
  → 繼續上一個 session。
- 還原 = 不用還原；下次直接跑 `claude` 完全不受影響。

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
  （`$COPILOT_CLAUDE_MODEL` 可覆寫狀態檔；最終預設是 `claude-opus-4.8`。）

行為：

- 模糊 id：`copilot-model opus-4.8` 會解析成 `claude-opus-4.8`。
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
    "ANTHROPIC_MODEL": "claude-opus-4.8",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4.8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4.5",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4.5",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` 會被代理忽略，但必須設定。
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` 可減少背景流量（有助於速率限制）。
**不要** 把這段貼進會 commit 的 `.claude/settings.json` —— 改用 `copilot-here on`。

## 陷阱 (gotchas)（這些都花了實際 debug 時間）

### 不要使用 Claude Code 內建的 `/model` 選單

它送出的是 Anthropic 的 *官方* id（例如 `claude-opus-4-8-YYYYMMDD`），但 Copilot 後端只
認得自己的 id（`claude-opus-4.8`）。從選單挑會產生：

```
API Error: 400 {"error":{"message":"The requested model is not supported.",
"code":"model_not_supported", ...}}
```

改用 `copilot-model` 釘選模型。

### 「Opus 4 retired」警告只是顯示問題 (cosmetic)

Claude Code 顯示 `[Opus 4]` 並警告 *"Claude Opus 4 was retired"* —— 它無法把 Copilot id
對應到內建的 Anthropic 表，於是退回最接近的（已退役）名稱。請求其實仍正確路由到
`claude-opus-4.8`。沒有乾淨的方法移除此警告；忽略即可。

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

經 `/v1/models` 驗證（2026-07）：`claude-opus-4.5`、`claude-opus-4.6`、
`claude-opus-4.7`、`claude-opus-4.8`、`claude-sonnet-4.5`、`claude-sonnet-4.6`、
`claude-sonnet-5`、`claude-haiku-4.5`。非 Claude 模型（gpt-5.5、
gemini-3.1-pro-preview…）也有提供 —— 見 `copilot-model -l` 或 `GET /v1/models`。

## 實用指令

```sh
claude-copilot                       # 一次性代理 session（specstory 包裝）
copilot-here status                  # 這個專案有釘在代理上嗎？
copilot-model -c                     # 目前模型 + 來自哪一層
copilot-proxy status                 # 有沒有在跑？提供哪些 Claude 模型？
copilot-proxy whoami                 # 驗證 token → 帳號 / plan / quota
copilot-proxy logs 60                # tail 代理的 log
# 用量儀表板 (dashboard)：
#   https://ericc-ch.github.io/copilot-api?endpoint=http://localhost:4141/usage
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
