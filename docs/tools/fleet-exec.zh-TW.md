# fleet exec — 跨主機臨時指令執行器

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`fleet exec` 在 fleet inventory (`~/.config/fleet/machines.toml`) 列出的每台
主機上跑任意指令，蒐集每台的 stdout + stderr + exit code，渲染為表格 —
也可選擇用 AI 分類成 succeeded / differed / failed。

姊妹工具：[`fleet pueue`](pueue.md)（結構化 queue 探測）、
[`fleet tmux`](../this_repo/fleet-apply.md#fleet-tmux--cross-host-tmux-session-summary)
（tmux session 摘要）、[`fleet info`](../this_repo/fleet-apply.md)
（系統資訊快照）。四者共用 `scripts/fleet_apply.py` 的 asyncssh +
semaphore 底層。

## 安裝

由 chezmoi 隨 `fleet` umbrella 自動部署：

- `~/.dotfiles/bin/fleet` — umbrella binary
- `~/.local/share/chezmoi/scripts/fleet/exec.py` — 實作（執行時透過
  `chezmoi source-path` 解析）

無需額外安裝。

## 三種執行模式 (正交 flag)

`--shell` / `--login` / `--no-augment-path` 互相獨立、可自由組合。預設
偏安全 (不展開 shell) 加快速 (不載入 rc 檔)。

| 模式 | Wire format | 何時使用 |
|------|-------------|----------|
| **預設 (argv list)** | `<argv shlex-quoted>` 透過 remote `sh -c` | 大多數 ad-hoc 指令。沒有 globs、pipes、`$VAR` 展開。保證安全。 |
| `--shell bash` | `bash -c '<argv 用空格 join>'` | 需要 pipe (`\|`)、glob (`*`)、redirect (`>`)、`&&`/`;` 鏈、或 `$VAR` 插值時。 |
| `--shell zsh` | `zsh -c '<...>'` | Zsh 特有語法 (`${(...)}`、`=~` 等)。 |
| `--login` | `bash -lc '<quoted argv>'` (或 `<shell> -lc`) | 需要 rc 載入的工具：`nvm`、`mise`、`pyenv`、`conda activate`、shell aliases/functions。每台慢 ~150-500ms。 |
| `--no-augment-path` | 直接 argv，不預先補 PATH | 除錯「這台 SSH 預設看到什麼 PATH」。與 `--login` 互斥。 |

組合：

```bash
fleet exec -- pueue --version                       # argv default
fleet exec --shell bash -- 'cat *.log | grep ERR'   # shell 取得 pipe + glob
fleet exec --login -- pueue --version               # rc 載入的環境
fleet exec --login --shell zsh -- 'conda activate myenv && python -V'
fleet exec --no-augment-path -- echo "\$PATH"       # raw SSH PATH
```

`--` 是標準 wrapper-CLI 分隔符 (同 `ssh`、`docker run`、`cargo run`、
`pytest`)。`--` 之後的東西對 fleet 自己的 option parser 不透明，所以內層
指令的 flag (如 `--version`、`-c`) 不會跟 fleet 的 flag 撞名。

## PATH 補完

跟 [`fleet pueue`](pueue.md) 一樣，本指令會在每台主機 prepend 固定的
PATH prelude，讓非互動 SSH shell 看得到使用者自行安裝的 binary：

```
~/.dotfiles/bin → ~/.cargo/bin → ~/.local/bin → ~/bin →
/opt/homebrew/bin → /usr/local/bin → /home/linuxbrew/.linuxbrew/bin →
~/.linuxbrew/bin → $PATH
```

順序刻意把 package-manager 路徑 (`~/.cargo/bin`、`~/.local/bin`) 放在
legacy `~/bin` 之前 — 這樣放在 `~/bin` 的舊版本檔案就不會蓋掉新的
`cargo install`。`--no-augment-path` 跳過 prelude；`--login` 繞過它
(login shell 從 rc 檔載入 PATH)。

這個順序刻意跟你互動 shell 的 PATH 順序不同 — 完整理由見
[pueue.md § PATH augmentation](pueue.md)。

## AI 摘要模式

`fleet exec --ai` 把每台主機的合併 JSON pipe 給設定好的 LLM agent
(優先順序 `opencode` → `claude` → `codex` → `cursor-agent`，依
`dot_config/shell/04_ai_agents.sh`)。LLM 分類每台：

| 分級 | 圖示 | 意義 |
|------|------|------|
| `succeeded` | 🟢 | rc=0 且 stdout 匹配 cluster majority |
| `differed` | 🟡 | rc=0 但 stdout 有意義地不同 (版本漂移、設定漂移、OS-specific 輸出) |
| `failed` | 🔴 | rc≠0 或 SSH/timeout 錯誤 |

範例輸出：

```
🌐 4 hosts on pueue 4.0.2, ts_nas lagging on 4.0.1 — consider upgrading NAS

majority: pueue 4.0.2

🟢 succeeded (4)
  self            rc=0     pueue 4.0.2 — matches cluster majority
  hanru_mac       rc=0     pueue 4.0.2 — matches cluster majority
  jingle207       rc=0     pueue 4.0.2 — matches cluster majority
  david_ubuntu    rc=0     pueue 4.0.2 — matches cluster majority

🟡 differed (1)
  ts_nas          rc=0     pueue 4.0.1 — one minor version behind
```

### Markdown reports

`fleet exec --ai --report --out PATH` 寫一份 markdown 文件，含 Summary
/ Succeeded / Differed / Failed 區段，加上每台 raw output 在可摺疊的
details block 內。適合分享審計結果、塞進 commit message、或歸檔某時刻
的 fleet 快照。

### Cache

結果快取在 `~/.cache/fleet-exec/<host>-<prompt_hash>.json` (TTL
`FLEETEXEC_MIN_REFRESH_INTERVAL` 秒，預設 120)。Cache key 是
`(prompt + 每台 stdout/stderr/rc)` 的 SHA — `elapsed_ms` **不**入 hash，
所以 SSH 時間變動不會讓相同輸出失去 cache。

強制刷新：`fleet exec --ai --refresh -- ...`。
完全跳過 cache：`fleet exec --ai --no-cache -- ...`。
不呼叫 LLM 看會送什麼：`fleet exec --ai --dry-run -- ...`。

## 輸出格式

```bash
fleet exec -- date                       # Rich table (預設)
fleet exec --json -- date                # JSON array
fleet exec --out-dir /tmp/exec-out -- df # 每台 .stdout/.stderr/.json
fleet exec --full-output -- df -h /      # 表格 + 每台輸出 block 在下方
```

預設表格顯示 stdout **第一行**，截斷至終端機寬度。對多行輸出的指令
(`df -h`、`ps -ef`、`systemctl status`)，通常想要 `--full-output` 或
`--out-dir`。

## 子集挑選

```bash
fleet exec --hosts self,ts_nas -- pueue --version    # 只跑指定子集
fleet exec --exclude jingle207 -- pueue --version    # 排除一個
fleet exec --serial -- pueue --version               # 一台一台 (debug)
fleet exec --max-parallel 4 -- pueue --version       # 限制並行
```

預設平行度 `min(8, len(hosts))`。SSH connect timeout: 15s。每台指令
timeout: 60s (用 `--command-timeout` 改)。

## Exit code

`fleet exec` exit 為 `min(N_failed, 125)`，N_failed 是 rc≠0 或
SSH/timeout 錯誤的台數。可用於 CI：

```bash
fleet exec --hosts production -- systemctl is-active myservice || alert.sh
```

## 常見審計菜單

```bash
# 版本漂移
fleet exec --ai -- pueue --version
fleet exec --ai -- python3 --version
fleet exec --ai -- chezmoi --version

# 磁碟壓力
fleet exec --ai -- df -h /

# Daemon 健康
fleet exec --shell bash -- 'systemctl --user is-active pueued 2>/dev/null || launchctl list | grep pueue'

# 重量級 process
fleet exec --shell bash -- 'ps aux | sort -k 4 -r | head -5'

# 確認檔案是否部署到每台
fleet exec -- test -f ~/.config/fleet/machines.toml

# Kernel 審計 (只 Linux — macOS 會 "failed")
fleet exec --ai -- uname -r
```

## 排錯

- **某工具明明裝了卻顯示 `not-installed`**：SSH 非互動 shell 的 PATH
  很簡。`--login` 會 expose 所有使用者安裝的工具 (慢)；預設的 PATH
  prelude 涵蓋常見位置但不是所有位置。
- **`bash -lc` 看不到我的 conda init**：只在 zsh 設定的 PATH 在
  `bash -lc` 下不會載入。改用 `--login --shell zsh`。
- **AI 模式卡住**：`fleet exec --ai --dry-run -- ...` 印出 prompt 但
  不呼叫 LLM。Prompt 看起來正常的話，問題在上游 (agent 不在 PATH、
  API key 等)。
- **AI 回不可解析 / 不是 JSON**：`--refresh` 重跑；持續壞的話用
  `--json` 自己處理。
- **沒有 `--clean`** (跟 `pqsum ai` 不同)：`fleet exec` 是通用指令
  runner；安全檢查由使用者負責。要跨機刪檔請明知故犯地用
  `fleet exec --shell bash -- 'rm ...'`。

## 跨檔案不變量

新增 flag 或改 output schema 要動：

1. `scripts/fleet/exec.py` — 主要實作
2. `dot_dotfiles/bin/executable_fleet` — USAGE block + `_dispatch_exec`
3. `docs/this_repo/fleet-apply.md` — subcommand 列
4. `docs/tools/fleet-exec.md` (+ zh-TW mirror) — 本頁

新增 AI agent 時，本腳本是 `dot_config/shell/04_ai_agents.sh` 的第 4
個 Python 消費者 — 見
[CLAUDE.md](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md)
AI-agent 列。
