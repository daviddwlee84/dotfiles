# Super Productivity — 本地 REST API 參考

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本文於 **2026-04-23** 對照上游 wiki 頁面
[`docs/wiki/3.01-API.md`](https://github.com/super-productivity/super-productivity/blob/master/docs/wiki/3.01-API.md)
與下列原始檔交叉驗證。請視為快照 (snapshot) — API 仍在積極演進。
若有疑慮，請從 wiki 與下方列出的原始檔重新生成。

> **這個頁面的初稿原本假設 wiki 不存在**，事實上是有的 — 上游
> `docs/wiki/3.01-API.md` 完整記錄了三個 SP API 系統 (Sync Server、Plugin
> API、Local REST API)。本檔只聚焦於我們使用的 Local REST API，並對 wiki
> 一筆帶過的安全模型 (security model) 與逆向觀察的行為提供額外細節。

## 三個 API 系統 — 區分用法

Super Productivity 暴露 **三個** 不同的 API 介面，請勿混淆：

| API | 用途 | 位置 | 認證 |
|---|---|---|---|
| **Sync Server REST API** | 透過 SuperSync provider 在不同裝置間同步使用者資料（**不是** WebDAV） | 遠端伺服器 (`packages/super-sync-server/`) | JWT Bearer |
| **Plugin API** | 為已安裝外掛 (plugin) 提供的應用內 `PluginAPI` 全域物件（在沙盒 VM/iframe 中執行） | 應用程式行程內部 | 無（由沙盒強制隔離） |
| **Local REST API** | 給同一台機器上外部腳本使用的 HTTP 控制介面 | 桌面 Electron app 中的 `http://127.0.0.1:3876` | 無 — 僅 localhost |

**本文件只涵蓋 Local REST API。** Television channel
[`tv super-productivity`](../../dot_config/television/cable/super-productivity.toml)
就是透過它來溝通。

Sync Server 與 Local REST API 是完全獨立的議題。
**啟用 Dropbox / WebDAV / SuperSync 作為同步 (sync) provider 對 Local REST
API 是否能運作毫無影響**。它們是兩個彼此獨立的開關。

## 版本要求（地雷）

Local REST API 由上游 PR
[#6981](https://github.com/super-productivity/super-productivity/pull/6981)
加入（合併於 2026-03-28），首次釋出於 **v18.0.0**（2026-03-26 release
cycle）。DNS-rebinding 強化則緊接著由 PR #6996 補上。

| 安裝版本 | Local REST API 是否可用？ |
|---|---|
| ≤ v17.x | **否** — 根本沒有 HTTP 伺服器，設定也不會出現 toggle |
| ≥ v18.0.0 | 可用 — 在 Settings → Misc 看得到 toggle |

確認你目前的版本：

```bash
defaults read "/Applications/Super Productivity.app/Contents/Info.plist" CFBundleShortVersionString
brew info --cask super-productivity | head -5    # 最新可用版本
```

Brewfile 中的 cask
([`dot_config/homebrew/Brewfile.darwin.tmpl:83`](../../dot_config/homebrew/Brewfile.darwin.tmpl))
鎖定 "latest"，但若你本機安裝落後，請執行
`brew upgrade --cask super-productivity`（或 `just upgrade-brew`）。

## 為什麼我們在意

我們利用 Local REST API 來驅動唯讀的 TV channel
[`tv super-productivity`](../../dot_config/television/cable/super-productivity.toml)
（[來源 script](../../dot_config/television/executable_super-productivity-source.sh)）。

撰寫本文時，**沒有官方 CLI**、也 **沒有官方 MCP server**。
"API" 議題（[#312](https://github.com/super-productivity/super-productivity/issues/312)）
從 2017 年開到現在；2025-03 有人提出「MCP server plugin」的構想，但沒
roadmap 承諾。對外部工具而言，Local REST API 是唯一官方的程式化介面，
而且它只在桌面 Electron app 執行時才能用。

Plugin API 對應用內擴充是合理的替代方案（內建的 `api-test-plugin`、
`sync-md` 外掛都用它），但外掛是 in-process 執行，不適合 shell 自動化。
shell 自動化還是用 REST。

## 來源真實性 (source of truth)

| 議題 | 上游檔案 |
|---|---|
| 官方面向使用者的參考 | [`docs/wiki/3.01-API.md`](https://github.com/super-productivity/super-productivity/blob/master/docs/wiki/3.01-API.md) |
| HTTP 伺服器、port、host 過濾、上限 | `electron/local-rest-api.ts` |
| 常數 + payload 結構 | `electron/shared-with-frontend/local-rest-api.model.ts` |
| 路由表 + handler 邏輯 | `src/app/core/electron/local-rest-api-handler.service.ts` |
| 單元測試（39 個案例，可當行為規格） | `src/app/core/electron/local-rest-api-handler.service.spec.ts` |
| Toggle 設定 key | `misc.isLocalRestApiEnabled`（全域 config 狀態） |
| Plugin API（獨立議題） | `packages/plugin-api/src/types.ts`、`docs/plugin-development.md` |

## 啟用 API

伺服器 **預設關閉**。啟用方式（僅 v18.0.0+）：

1. 開啟 Super Productivity 桌面 app
2. **Settings → Misc → "Enable local REST API"**
   *(不是 "Sync & Export" — 那一節是設定 Dropbox/WebDAV/SuperSync 的資料同步，跟 REST API 無關。)*
3. 重啟 app（toggle 在下次啟動才生效，不是即時）

驗證：

```bash
curl -s http://127.0.0.1:3876/health | jq
# {"ok":true,"data":{"server":"up","rendererReady":true}}
```


故障模式：

| Curl exit | 代表意義 |
|---|---|
| `7` (connection refused) | App 沒在跑，或 API toggle 關著 |
| `28` (timeout) | App 卡住；檢查 renderer process |
| `200` 但 `rendererReady: false` | 伺服器起來了但 Angular renderer 還沒初始化 — 除了 `/health` 之外的所有路由都會回 `503 APP_NOT_READY` |

## 伺服器常數

來自 `electron/shared-with-frontend/local-rest-api.model.ts`：

| 常數 | 數值 |
|---|---|
| `LOCAL_REST_API_HOST` | `127.0.0.1`（僅 localhost — 不會綁外部介面） |
| `LOCAL_REST_API_PORT` | `3876` |
| `LOCAL_REST_API_TIMEOUT_MS` | `15000`（renderer round-trip timeout） |
| `LOCAL_REST_API_MAX_BODY_BYTES` | `1048576`（請求 body 上限 1 MiB） |
| `LOCAL_REST_API_MAX_CONCURRENT_REQUESTS` | `50` |

## 安全模型

- **DNS-rebinding 防護**：伺服器會檢查 `Host:` header。允許的值：
  `127.0.0.1:3876`、`127.0.0.1`、`localhost:3876`、`localhost`。
  其它任何值都會回 `403 FORBIDDEN`。所以你不能用自訂 DNS 名稱
  （例如 `sp.local`）與它對話。
- **除了 Host 過濾之外沒有任何認證**。任何能在這台機器上連到 localhost
  的程式都能讀寫你的任務 (task)。如果你要透過 SSH port-forward 把它公開出去，請斟酌。
- **併發上限**：超過 50 個 in-flight requests 時伺服器回
  `429 TOO_MANY_REQUESTS`。
- **不會送出 CORS headers**；瀏覽器發起的呼叫會被擋，除非該頁面就是
  renderer 自己提供的。

## 回應外殼 (response envelope)

每個回應都是 JSON，且為下列其中一種結構：

```json
{ "ok": true,  "data": <any> }
{ "ok": false, "error": { "code": "STRING", "message": "STRING", "details"?: <any> } }
```

**`data` 包裝是通用的** — 下方路由表中每一個 "Returns" 條目描述的是
`data` 的結構，**不是** 頂層回應。用 `jq` 處理時請先抽出 `.data`：

```bash
# 對的
curl -sf http://127.0.0.1:3876/tasks | jq '.data[].title'
curl -sf http://127.0.0.1:3876/tasks/$ID | jq '.data.notes'
curl -sf http://127.0.0.1:3876/task-control/current | jq -r '.data.id // empty'

# 錯的（會跳 "Cannot index boolean with string" — .ok 是 bool）
curl -sf http://127.0.0.1:3876/tasks | jq '.[].title'
```

當前任務若為 `null`，會以 `{"ok":true,"data":null}` 回傳，而不是
`{"ok":true}` — 所以 `jq -r '.data.id // empty'` 是安全寫法。

已知的錯誤代碼（來自 renderer + server）：

| Code | HTTP | 何時 |
|---|---|---|
| `FORBIDDEN` | 403 | `Host:` header 錯誤 |
| `TOO_MANY_REQUESTS` | 429 | 同時超過 50 個請求 |
| `APP_NOT_READY` | 503 | 伺服器起來但 renderer 還沒初始化 |
| `INVALID_REQUEST_BODY` | 400 | Body 存在但不是合法 JSON |
| `INVALID_INPUT` | 400 | Body 解析過了但路由特定的驗證沒過 |
| `TASK_NOT_FOUND` | 404 | `:id` 對不到任何任務（active 或 archive 取決於路由） |
| `NOT_FOUND` | 404 | 路由不在表上 |
| `RENDERER_TIMEOUT` | 504 | Renderer 15 秒內沒回應 |
| `INTERNAL_ERROR` | 500 | 其他 |

## 路由表

所有路由都接收與回傳 JSON。`:id` 是字串（類 UUID），由 app 產生。
Query params 透過 `URL.searchParams` 解析 — 重複 key 會變陣列，
單一 key 是字串。

### Health

| Method | Path | Returns |
|---|---|---|
| `GET` | `/health` | `{server: "up", rendererReady: bool}` — 唯一在 renderer 還沒初始化前就能用的路由。 |

### App status

| Method | Path | Returns |
|---|---|---|
| `GET` | `/status` | `{currentTask, currentTaskId, taskCount}` — `currentTask` 是完整任務物件或 `null`。 |

### Current task control

| Method | Path | Body | Returns |
|---|---|---|---|
| `GET` | `/task-control/current` | — | 完整當前任務或 `null` |
| `POST` | `/task-control/current` | `{taskId: string \| null}` | `{currentTaskId}` — 啟動（聚焦）一個任務；傳 `null` 可清除 |
| `POST` | `/task-control/stop` | — | `{currentTaskId: null}` — 停止當前任務 |

### Tasks（集合）

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tasks` | 列表，可篩選。Query params：`query`（對 `title` 不分大小寫子字串比對）、`projectId`、`tagId`、`includeDone`（bool，預設 `false`）、`source`（`active` \| `archived` \| `all`，預設 `active`）。四個篩選都已用實際資料驗證可用。 |
| `POST` | `/tasks` | 建立。Body 必須包含 `title`（非空字串）。其它允許欄位由伺服器端白名單控管：見下方「允許可變更欄位」。回傳建立完的任務，狀態 `201`。 |

### Tasks（單筆）

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tasks/:id` | 回傳任務物件。找不到時 `404 TASK_NOT_FOUND`。 |
| `PATCH` | `/tasks/:id` | Body 是部分任務；只套用白名單內的欄位 — 多餘欄位會靜默丟棄。**`notes` 是整段取代，不是追加。** |
| `DELETE` | `/tasks/:id` | 移除任務（連同 sub-tasks）。回傳 `{deleted: true, id}`。 |
| `POST` | `/tasks/:id/start` | 將任務設為當前聚焦的任務。等同於 `POST /task-control/current` 並傳 `{taskId: id}`。 |
| `POST` | `/tasks/:id/archive` | 將任務（連同 sub-tasks）移到 archive。 |
| `POST` | `/tasks/:id/restore` | 從 archive 還原。不在 archive 中時 `404 TASK_NOT_FOUND`。 |

### Projects

| Method | Path | Notes |
|---|---|---|
| `GET` | `/projects` | 列出所有專案 (project)。Query：`query` 對 title 做子字串篩選。沒有 create/update/delete 路由。 |

### Tags

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tags` | 列出所有 tag。Query：`query` 對 title 做子字串篩選。沒有 create/update/delete 路由。 |

### 允許可變更欄位

伺服器在 `POST /tasks` 與 `PATCH /tasks/:id` 上強制白名單 — 其餘欄位
都會無聲丟棄。出自 `local-rest-api-handler.service.ts`：

```text
title, notes, isDone, timeEstimate, timeSpent,
projectId, tagIds, dueDay, dueWithTime, plannedAt
```

含意：

- 不能透過 REST 設定 `subTaskIds`、`parentId`、`_projectId`、`attachments` 等。
- 不能對 `notes` 做 append — 必須先 `GET`、編輯、再 `PATCH` 整個字串。
- `timeSpent` 可以設定，這比較少見：讓外部計時器能繞過 focus-task 流程回填工時。

## 沒有暴露的功能

下面是常見需求但目前 API **不支援** 的項目。在依賴「沒有」這件事之前，
請先再次去上游確認 — API 還在持續加東西。

- **沒有 "today" 路由**。"Today" 視圖是 renderer 端聚合 — 經實證觀察包含
  `dueDay == today` 的所有任務、聚焦中的當前任務、以及帶內建 `TODAY` tag
  的任務。TODAY tag 有固定保留 id，已對實際資料驗證：`id == "TODAY"`，
  與語系或顯示標題無關（`title` 顯示在地化的 "Today" 字串）。其它內建項目
  也是同樣的固定 id 模式：`KANBAN_IN_PROGRESS`、`EM_IMPORTANT`、`EM_URGENT`
  （tag）以及 `INBOX_PROJECT`（project）。所以 `GET /tasks?tagId=TODAY`
  只是部分近似 — 容易查，但會漏掉只設了 `dueDay` 而沒打 tag 的項目。
  忠實重建 Today 需要 `dueDay == today` ∪ `tagId=TODAY` ∪ 當前任務。
- **沒有 recurring task 建立**。已在上游追蹤（issue 開於 2026-04-16）。
- **沒有 notes 追加**。請用 `PATCH` 傳完整新字串。
- **沒有 project / tag 的 CRUD**。唯讀。
- **沒有 worklog / 時間追蹤 session API**。可以用 `PATCH` 改 `timeSpent`，
  但沒有事件式 endpoint。
- **沒有透過 REST 處理 attachments / sub-tasks 的端點**。雖然它們會在
  `GET`/`PATCH` 裡來回，但沒有專門新增 sub-task 的 endpoint。
- **沒有 webhooks / SSE / WebSocket**。只能輪詢 — 見 TV channel 的 `watch = 5.0`。
- **沒有驗證過的深層連結 URL scheme**。撰寫本文時，搜尋上游 repo 的
  `superproductivity://` 沒有任何結果。請別假設它存在而組連結。

## 進階到程式化控制的計畫

與上游方向確認一致（desktop-only、plugin 友善、API-first）：

```
Super Productivity Desktop
    └── Local REST API (127.0.0.1:3876)
            └── tv super-productivity              ← v0.1（本 PR），唯讀
            └── 未來: spctl                        ← 暫緩 (P? in TODO.md)
            └── 未來: super-productivity-mcp       ← 暫緩 (P? in TODO.md)
```

TV channel 刻意把每個讀取路由都跑過一次，這樣未來的 CLI 或 MCP server
都能複用同樣的 shell-level 整合測試。改變狀態的操作（start、stop、
complete、archive）刻意不放進 v0.1 — 路由都存在
（`POST /task-control/stop`、`POST /tasks/:id/start`、
`PATCH /tasks/:id` 帶 `{isDone:true}`、`POST /tasks/:id/archive`），
但要先驗證行為再導入。

## 驗證本文件

若上游 renderer service 檔有變動，重新產生路由表：

```bash
gh api -X GET "repos/super-productivity/super-productivity/contents/src/app/core/electron/local-rest-api-handler.service.ts" \
  --jq '.content' | base64 -d | grep -E "method === '|path === '|segments\["
```

上方路由表與 `_routeRequest` 中的 `if` 分支（加上處理 `/tasks/:id/...`
的內層 `_handleTaskRoutes` 案例）為 1:1 對應。
