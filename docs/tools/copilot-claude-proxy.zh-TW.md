# Copilot → Claude Code 代理 (proxy)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

用 **GitHub Copilot** 訂閱裡的 Claude 模型來驅動
[Claude Code](https://docs.anthropic.com/en/docs/claude-code)，透過本機的逆向工程
(reverse-engineered) 代理 (proxy)
[`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api)。

- **Shell helpers**：`~/.config/shell/43_copilot_proxy.sh`（`copilot-proxy`、`copilot-model`）
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
copilot-proxy start     # 背景啟動代理（預設 port 4141）

# 在你的專案目錄建立 .claude/settings.json 指向代理
# （見下方「專案設定」），然後：
copilot-model -c        # 確認釘選的模型
claude                  # 執行 Claude Code —— 它會讀取 ./.claude/settings.json
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
- `.claude/settings.json` 透過 `ANTHROPIC_BASE_URL` 把 Claude Code 指向代理。

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

### `copilot-model [<id>|-l|-c]`

切換 **目前目錄** 的 `.claude/settings.json` 釘選哪個 Copilot 模型。需要 `jq`。

- 模糊 id：`copilot-model opus-4.8` 會解析成 `claude-opus-4.8`。
- 會對照即時的代理 `/v1/models` 驗證（代理未啟動時退回靜態 Claude 清單）；打錯字與不明確的
  前綴會被拒絕。
- 無參數 → `fzf` 選單。
- 同時寫入 `ANTHROPIC_MODEL` 與 `ANTHROPIC_DEFAULT_OPUS_MODEL`，然後印出重啟提醒 ——
  **變更只在下次 `claude` 啟動時生效**（env 在啟動時讀取）。切換模型 **不需要** 重啟代理。

## 專案設定 (`.claude/settings.json`)

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
copilot-proxy status                 # 有沒有在跑？提供哪些 Claude 模型？
copilot-proxy whoami                 # 驗證 token → 帳號 / plan / quota
copilot-proxy logs 60                # tail 代理的 log
# 用量儀表板 (dashboard)：
#   https://ericc-ch.github.io/copilot-api?endpoint=http://localhost:4141/usage
```

## 參見

- [copilot-api](https://github.com/ericc-ch/copilot-api) —— 代理本體
- [`bunx` CLI aliases](../shells/aliases.md#copilot--claude-code-代理-proxy)
- OpenCode 原生的 GitHub Copilot provider（OpenCode 本身不需要代理）
