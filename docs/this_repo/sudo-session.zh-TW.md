# `chezmoi apply` 的共享 sudo 會話

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

三個 `run_*` 腳本 (`run_once_before_00_bootstrap.sh.tmpl`、`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`、`.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`) 透過 `scripts/lib/sudo_shared.sh` 共享單一個 sudo 會話 (session)。使用者只會在 `chezmoi apply` 一開始被提示**一次**，所有下游腳本都會靜默地重複使用快取 (cache) 過的憑證。

> **新 run-script 的硬性規則**：不要重複實作 `sudo -k` / `sudo -v` / TTY-read 邏輯。改呼叫共享的輔助函式 (helper)。

## 如何串起來

- 輔助函式位於 `scripts/lib/sudo_shared.sh`（純 bash，約 270 行）。它**從不被部署** — `scripts/**` 在 `.chezmoiignore.tmpl` 之中。
- 每個 `run_*.sh.tmpl` 在渲染時透過 `{{ include "scripts/lib/sudo_shared.sh" }}` 將輔助函式內嵌 — 不在執行階段 (runtime) source、也不需查找回原始碼樹的路徑。
- 模板期 (template-time) 的 `NEED_SUDO` 旗標 (`1`/`0`) 會在整個流程中沒有腳本會碰 sudo 時短路掉整套機制（例如 Linux 上 `noRoot=true`，或 macOS 上沒有 `installBrewApps`/`installInputMethod`）。

## 執行階段狀態

放在 `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/` 下（mode 0700；當 `$XDG_RUNTIME_DIR` 未設定時退回 `${TMPDIR:-/tmp}/chezmoi-sudo-$UID/`）：

| 檔案 | Mode | 內容 |
|------|------|----------|
| `sudo.pass` | 0600 | 原始密碼 + `\n`，由 `sudo_run` 透過管線送進 `sudo -S` |
| `ansible-become.yml` | 0600 | 給 `ansible-playbook -e @file` 用的 `ansible_become_password: "…"` YAML |
| `keepalive.pid` | 0600 | 分離出去的監督 (watchdog) PID |
| `chezmoi.pid` | 0600 | watchdog 監視的祖先 chezmoi PID |

## 清理模型

採用混合策略，因為每個腳本各自的 `trap … EXIT` 會在*下一個*腳本能重複使用之前就把狀態清除：

- 信號 trap：`INT`/`TERM`/`HUP` → `sudo_session_abort` 殺掉 watchdog 並 `rm -rf` 狀態目錄。使用者按 Ctrl+C 不會把秘密留在磁碟上。
- 流程結束清理 → watchdog（透過 `setsid` 分離出去）監視 chezmoi 的祖先 PID。當 chezmoi 退出時，watchdog 自我終止並 `rm -rf` 狀態目錄。它每 50 秒刷新 TTY sudo 時間戳 (timestamp)，讓 cask pkg 安裝程式 (`sudo /usr/sbin/installer`) 能找到有效的 ticket。

## 公開 API

三個 run-script 都會用到以下：

| 函式 | 用途 |
|---|---|
| `sudo_session_init [label]` | 冪等 (idempotent)：若狀態有效則重新 export 環境變數 (env var)；否則在 `/dev/tty` 上提示一次、驗證、寫入檔案、產生 watchdog。在既不是 passwordless 也不是 TTY 互動模式時回傳非零。在任何 sudo 之前先呼叫這個。 |
| `sudo_run <cmd ...>` | 薄包裝 (wrapper)：`sudo -S -p '' -- "$@" <sudo.pass` — 透過管線送入快取的密碼，絕不放進 argv。Passwordless 時退回純 `sudo`。用於 bootstrap 的 `apt-get` 呼叫。 |
| `sudo_session_skip_reason` | 分支輔助函式。印出 `"cached"` / `"passwordless"` / `"non-interactive"` / `""`。被 ansible + brew 腳本用來在 `-e @file`、`""` flag 或手動指引退回方案之間做選擇。 |
| `sudo_session_warm_cache` | 用快取的密碼刷新目前 TTY 的 sudo 時間戳。在 `brew bundle` 這類其 cask pkg 安裝程式會內部呼叫 `sudo` 並依賴時間戳快取（而不是接受透過管線送入的密碼）的工具之前呼叫。 |

**成功時的 export**：`CHEZMOI_SUDO_STATE_DIR`、`CHEZMOI_SUDO_PASS_FILE`、`CHEZMOI_ANSIBLE_BECOME_FILE`、`CHEZMOI_SUDO_KEEPALIVE_PID`。

## 非互動式密碼注入 (`CHEZMOI_SUDO_PASSWORD_FILE`)

被消費端沒有 TTY 的遠端協作器 (orchestrator) 使用 — 目前是
[`scripts/fleet_apply.py`](../../scripts/fleet_apply.py) 透過 SSH。

當 `sudo_session_init` 被呼叫且：

1. 共享狀態目錄**尚未**被填充，且
2. Sudo **不是** passwordless，且
3. `CHEZMOI_SUDO_PASSWORD_FILE` 環境變數指向一個可讀的、包含密碼的檔案
   （一行，結尾 `\n` 為選填），

那麼該檔案會被讀取、用 `sudo -S -v -p ''` 驗證，並按它原本就被互動式輸入過的方式採納進共享狀態目錄。Watchdog 也以同樣方式產生；後續 run-script 命中 cached-state 分支，永遠看不到該環境變數（在採納後它會被 `unset`）。

如果密碼被 sudo 拒絕，init 會以清晰的 stderr 訊息失敗，而不是靜默退到 TTY 分支。

控制端的協作器負責把那個 0600 檔案放到遠端、並負責清理 — 合約 (contract) 見
[`docs/this_repo/fleet-apply.md`](fleet-apply.md)。

## 在 run-script 中新增 sudo 介面

1. 在模板上方附近 `{{ include "scripts/lib/sudo_shared.sh" }}`。
2. 為你的腳本決定 `NEED_SUDO` 模板旗標（對照現有 run-script 的條件）。
3. 呼叫 `sudo_session_init "yourlabel"`；依回傳碼 + `sudo_session_skip_reason` 分支。
4. 透過 `sudo_run …` 執行特權命令（簡單情境），或將 `-e @$CHEZMOI_ANSIBLE_BECOME_FILE` 傳給 ansible。

## 不要做的事

- 執行 `sudo -k`（會讓整個流程的共享快取失效）。
- 註冊會移除狀態的 `trap … EXIT`（下一個 run-script 還需要它）。
- 把密碼讀進 shell 變數並留在那裡 — 永遠透過 `sudo -S <file`，絕不要當成環境變數或命令引數。
