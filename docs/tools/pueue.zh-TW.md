# pueue — 任務佇列 + AI 總結 + 跨主機檢視

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本機 CLI 加上一個 fleet 跨機指令，用於 [pueue](https://github.com/Nukesor/pueue)
（一個平行任務佇列 (task queue)）。三層：

- `pqsum` — 本機佇列摘要。三種模式：deterministic 表格 (`text`，預設)、附
  cleanability + recovery 判定的 AI 總結 (`ai`)、機器可讀的解析後 JSON (`json`)。
- `fleet pueue` — 透過 SSH 在 `~/.config/fleet/machines.toml` 列出的每台
  主機上跑同樣的檢視。**本輪只讀** (no `pueue add` / `clean` over SSH)；寫入操作
  延後到未來的 TLS 層。
- `tv pueue` — 對 running/finished 任務的終端選擇器 (terminal picker) UI
  (既有 cable，本次不動)。

## 安裝

由 chezmoi 自動部署：

- `pueue` + `pueued` 透過 Homebrew (macOS) 或 `cargo install pueue --locked`
  + systemd-user service (Linux)。見 `dot_ansible/roles/devtools/` 與
  `dot_ansible/roles/rust_cargo_tools/`。
- `~/.dotfiles/bin/pqsum` — 本次新增的 uv-script binary。
- `~/.dotfiles/bin/fleet` — 加入 `pueue` 子指令 (本次新增)。

macOS 上 pueue daemon **尚未** 自動啟動 (手動跑 `pueued`，或塞在 tmux/launchd
裡)。Linux 上由 user-level systemd unit 管。

## `pqsum` — 本機摘要

```bash
pqsum                       # 文字表格 (overall + status breakdown + groups)
pqsum --group default       # 限定單一 group
pqsum json                  # 解析後 JSON 到 stdout (envs 已剝除)
pqsum ai                    # 附 cleanability + recovery hints 的 AI 總結
pqsum ai --report           # markdown 報告到 stdout
pqsum ai --report --out ~/notes/pueue-2026-05-13.md
pqsum ai --clean            # 報告後，逐 safe-to-clean group 詢問 y/N
pqsum ai --clean --yes      # 同上但跳過詢問
```

### Cleanability 分級 (對應 `tsum` 的 safe/check/keep)

AI 對每個 group 評等：

| 分級 | 意涵 | 建議動作 |
|------|------|----------|
| 🟢 `safe-to-clean` | 所有任務 `Done` + `Success`，最後一個結束 >2 小時前，無 queued/paused。 | `pueue clean -g <group>` |
| 🟡 `review` | 混合 Done+Failed、最近 (<2h)、或含 Stashed/Paused。 | 清掉前先看。 |
| 🔴 `keep` | 有 Running/Queued、新失敗 (<10min) 還沒給 recovery hint、或 `--after` 鏈未完成。 | 別碰。 |

保守偏向是刻意的：LLM 被指示在不確定時挑更安全的那一級
(`keep > review > safe-to-clean`)。`pqsum ai --clean` **只**對
`safe-to-clean` 動手 — `review`/`keep` 即使 `--yes` 也絕不自動清。

### Failed 任務的 recovery hints

對每個 Failed/Killed 任務 AI 會給 `recovery_hint` + 可選的
`recovery_command`。prompt 內的 heuristics：

| 訊號 | Hint |
|------|------|
| 同 group 後續有指令字串相同的 Done 任務 | 「already covered by task N」 |
| Exit 124 | timeout → 「increase --timeout, then `pueue restart`」 |
| Exit 137 | OOM-kill → 「increase memory; `pueue restart`」 |
| Exit 143 | SIGTERM → 「transient; `pueue restart`」 |
| 連續多任務同一 exit code | 「group/env 設定錯誤，不是單任務問題」 |
| Paused >24h | 「stale; `pueue start` 或 `pueue remove`」 |

Recovery commands **永遠不會**被 `--clean` 自動執行 — 那個 flag 只動
`safe-to-clean` 的清理。未來會有 `--restart-failed` flag (TODO.md 追蹤)
帶相同的 y/N 安全機制做 recovery commands。

### AI cache

結果快取在 `$XDG_CACHE_HOME/pqsum/<host>-<prompt_hash>.json` (預設
`~/.cache/pqsum/`)。`PQSUM_MIN_REFRESH_INTERVAL` 秒內 (預設 120) 的重跑
直接重用快取。強制刷新：`pqsum ai --refresh`。

### Agent 選擇

與 `tsum` / `aifix` / `aiblock` 共用同一個 SSOT：
`dot_config/shell/04_ai_agents.sh`。優先順序 (env var
`AICAP_AGENT_PRIORITY`)：`opencode claude codex cursor-agent`。單次覆蓋：
`AICAP_AGENT=claude pqsum ai`。

## `fleet pueue` — 跨主機

```bash
fleet pueue                          # 表格：host × group 列
fleet pueue --json                   # 每台主機一筆，附解析後 snapshot
fleet pueue --hosts self,ts_nas      # 子集
fleet pueue --group default          # 跨主機只看單一 group
fleet pueue --ai                     # 跨主機 AI 總結
fleet pueue --ai --report --out ~/notes/fleet-pueue.md
```

### 運作方式

1. SSH-exec 一個小 shell sentinel，印
   `PQSUM_SOURCE=ok\n<raw pueue JSON>` (或 `=missing` / `=offline` 表示
   pueue 沒裝或 daemon 沒跑)。
2. OK 的 host 把 raw JSON 透過 **本機** `pqsum json --raw-stdin
   --host=NAME` 解析，parser 只活在一處。
3. 渲染每 (host, group) 一個 Rich row，或 `--json` 印 per-host 記錄，或
   `--ai` 合併後 pipe 到 `pqsum ai --stdin-json --multi-host`。

底層重用 `scripts/fleet/` 的 asyncssh + semaphore-8 (與 `scripts/fleet/tmux.py`
跟 `scripts/fleet/info.py` 同)；單主機失敗只影響該列，不中斷整個 run。

### 為何 `--clean` 限本機

跨主機 `pueue clean` 要嘛 (a) SSH-exec 破壞性操作而沒有逐主機確認，要嘛
(b) 上游 TLS remote-connect 層 (見下)。互動 y/N 在 5 hosts × 3 groups =
15 個 prompt 下也不好用。目前：用本機 `pqsum ai --clean` 或 `ssh HOST
pueue clean ...` 逐台處理。

## 延後：TLS remote-connect

Pueue 支援 [native remote-connect 協定](https://github.com/Nukesor/pueue/wiki/Connect-to-remote)
— daemon 綁 `0.0.0.0:port`、客戶端用 TLS cert + shared secret 直接呼叫
`pueue -c HOST add/kill/status`。這會解鎖跨機寫入 (`fleet pueue --clean`、
`fleet pueue add ...`)。TODO.md 追蹤為 `[?/M] Pueue TLS remote-connect
profiles`。目前 fleet 保持 SSH-only 唯讀。

## 跨檔案不變量

`pqsum json` (或 `pqsum json --raw-stdin --host=NAME`) 輸出、與
`pqsum ai --stdin-json --multi-host` 消費的 schema 是兩個腳本間的契約。
`scripts/fleet/pueue.py` 是唯一另一個消費者，依賴 schema 穩定。

在 `dot_dotfiles/bin/executable_pqsum` 的 `HostSnapshot`、`GroupRec`、
`TaskRec` dataclass 加欄位時：

1. 改 dataclass。
2. 如果該欄位需要進 LLM，改 `_host_to_ai_input()`。
3. 如果 LLM 需要拿這個欄位做判定，改 `PROMPT_PREAMBLE`。
4. 驗證 `fleet pueue --json | jq` 看得到新 key。
5. 重看本頁 `docs/tools/pueue.md` (zh-TW) 是否有過時表格。

見 [CLAUDE.md](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md) 的 "fleet" 列。

## 排錯

- **`pqsum: pueue not found in PATH`** — brew/cargo 裝一下，或從 ansible
  provisioned shell 進來。用 `command -v pueue` 確認。
- **`pqsum: failed to query pueue status`** — daemon 沒跑。`pueued -d`
  啟動；Linux 查 systemd unit (`systemctl --user status pueued`)。
- **AI 模式 hang 住 / 回不可解析的內容** — PATH 上沒 agent 或 LLM 回
  non-JSON。`pqsum ai --dry-run` 印 prompt 不呼叫 LLM；
  `AICAP_AGENT=http AICAP_HTTP_API_KEY=... pqsum ai` 強制 HTTP fallback。
  下次成功後 cache 自動修復。
- **`fleet pueue` 顯示 `daemon-offline`/`not-installed`** — 該主機 daemon
  沒跑或 pueue 沒裝。在該機修；重跑。
- **`pueue status --json` 輸出有 secrets** — pueue 為每個任務捕捉
  `pueue add` 那個 shell 的整份環境變數。`pqsum` 的 parser 在任何下游
  使用前 (AI prompt、JSON 輸出、cache) 都會剝除 `envs`。**永遠不要**把
  raw `pueue status --json` pipe 給別的東西 — 用 `pqsum json`。
