# `fleet_apply.py` vs. 2018 年代的 Fabric (`fabfile.py`)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

對本倉庫的 [`scripts/fleet_apply.py`](../../scripts/fleet_apply.py) 與作者較早期的
[RaspPi-Cluster `fabfile.py`](https://github.com/daviddwlee84/RaspPi-Cluster/blob/master/fabfile.py)
（Fabric 1.x，約 2018 年）進行並列比較。兩者解決相同形狀的問題——一台協調器 (controller)
將命令分派 (fan out) 至 N 台機器——但兩者的實作之間隔了約 7 年累積的營運痛點 (operational pain)。

保留在此作為「為什麼 fleet-apply 長這個樣子？」的考古紀錄。
不論用哪一個工具都不需先讀這頁。

## 同樣的概念，兩個年代

| 關注點 | RaspPi-Cluster `fabfile.py` (Fabric 1.x) | `scripts/fleet_apply.py` (asyncssh) |
|---|---|---|
| 主機清冊 (inventory) | `env.hosts` + `env.passwords` 直接寫死於檔案頂端 | `~/.config/fleet/machines.toml`（`load_hosts`，[fleet_apply.py:101](../../scripts/fleet_apply.py#L101)） |
| 平行分派 | `@parallel` decorator（執行緒池 (thread pool) 包住 paramiko） | `asyncio.TaskGroup` + 信號量 (semaphore)（單執行緒協程 (coroutine)） |
| Sudo 密碼注入 | `env.passwords[host] = pw`；Fabric 預期並餵入提示 | 推送至遠端 `~/.cache/chezmoi-fleet/sudo.pass`（0600）+ `CHEZMOI_SUDO_PASSWORD_FILE`（[fleet_apply.py:240](../../scripts/fleet_apply.py#L240)） |
| 遠端命令執行 | `sudo()` / `run()` | `conn.create_process(cmd)`（[fleet_apply.py:807](../../scripts/fleet_apply.py#L807)） |
| ssh_config 別名 (alias) 支援 | 原生（Fabric 透過 OpenSSH 的 shell 子程序） | asyncssh 為該別名讀取 `~/.ssh/config`（[fleet_apply.py:550](../../scripts/fleet_apply.py#L550)） |
| 任務 (task) 框架 | `fab install_dependencies` / `fab change_hostname` | `just fleet-apply` / `just fleet-apply-file PATH` |

如果你只在意「一個進入點，把命令 ssh 到一串機器，收回 exit code」——它們是同一個工具，只是不同年代。

## 這 7 年買到了什麼

### 1. 並行模型：執行緒 → 協程

- **Fabric 1.x**：`@parallel` 為每台主機開一條 OS 執行緒（底下是 paramiko）。在 5–20 台主機時表現尚可；幾百台時 FD/堆疊壓力很大。
- **fleet_apply.py**：單執行緒 `asyncio` + `asyncssh`。可擴展性更佳；信號量 (`--max-parallel`) 在沒有執行緒開銷的情況下界定並行數。

### 2. Ctrl+C / 通道斷線時的 process tree 清理

fabfile 完全沒做——在協調器上按 `Ctrl+C` 會在每台 Pi 上留下孤兒 (orphan) `apt-get` / `pip install` 程序。

`fleet_apply.py` 把清理疊了三層
（[fleet_apply.py:430–486](../../scripts/fleet_apply.py#L430)）：

1. `set -m`，這樣每個被背景化的子程序會擁有自己的 process group。
2. 在包裝 (wrapper) shell 中設置 `trap 'pkill -TERM -P $_cz_pid; kill -TERM $_cz_pid' INT TERM HUP`。
3. asyncssh 設定 `request_pty=True`，這樣關閉通道會把 SIGHUP 送達遠端 shell，並觸發 trap。

再加上 `--kill-orphans` 作為清道夫，處理三層都漏掉的情況。

### 3. 協調器死掉之後的可觀測性 (observability)

- **Fabric**：stdout 在多台主機間交錯；終端機掛了，整輪也就沒了。
- **fleet_apply.py**：
  - 每次執行都在遠端產生 `~/.cache/chezmoi-fleet/logs/<run_id>.log` + `.exit` 哨兵檔。
  - `--tail HOST[:RUN_ID]` 可重新接上仍在執行中的遠端。
  - `--status [--watch N]` 輪詢「每台主機上的 chezmoi/ansible 是否還活著？」
  - 本地 `logs/fleet-apply/<UTC>/<host>.log` 鏡射相同的串流。

### 4. 即時 UI

Rich 的 `Live` 表格會在執行過程中為每台主機呈現狀態 / 已耗時 / rc / 最後一行
（[fleet_apply.py:897](../../scripts/fleet_apply.py#L897)）。Fabric 只會印出交錯的 stdout。

### 5. 漂移 (drift) 分類（chezmoi 專屬）

`_classify_drift()`（[fleet_apply.py:520](../../scripts/fleet_apply.py#L520)）
會在 chezmoi 的 stderr **僅** 含「could not open a new TTY」這類提示時，
把 `rc != 0` 從 `failed` 降級為 `drift`——意即 `--keep-going` 略過了遠端被手動修改過的目標。
該主機顯示為黃色 ⚠ 並列出漂移路徑，但**不會**計入 exit code。詳見
[fleet-apply.md → "drift ≠ failed"](fleet-apply.md)。

Fabric 沒有等價概念；rc != 0 一律是失敗。

### 6. Sudo session 模型

- **Fabric**：`env.passwords` 存在協調器記憶體中；每次 `sudo()` 呼叫都重新等待提示並重新餵入密碼。
- **fleet_apply.py**：密碼**只寫一次**到遠端的 0600 檔案，然後由
  [`scripts/lib/sudo_shared.sh`](../../scripts/lib/sudo_shared.sh) 的 `sudo_session_init`
  透過 `sudo -S -v -p ''` 採用 (adopt)。同一次 `chezmoi apply` 中的 22+ 個 ansible role
  全都重複使用快取憑證——每個任務都不必再 expect 一次。詳見
  [sudo-session.md](sudo-session.md) → 「Non-interactive password injection」。

### 7. 密碼來源

Fabric：只支援程式碼內明文。

fleet_apply.py 支援四種（[fleet_apply.py:59](../../scripts/fleet_apply.py#L59)）：

| 類型 | 行為 |
|---|---|
| `plain` | TOML 中的值（請設好檔案權限） |
| `prompt` | 啟動時對每台主機呼叫一次 `getpass()` |
| `bitwarden` | `bw get password <item>`（需要已解鎖的保險庫 + `BW_SESSION`） |
| `none` | 不使用 sudo（對應 chezmoi init 的 `noRoot=true`） |

### 8. 本地主機 = 同一份程式路徑

`host.local = true` 會略過 SSH，直接以本地子程序執行 `chezmoi`
（[`run_one_local`，fleet_apply.py:597](../../scripts/fleet_apply.py#L597)），
共享協調器的 PATH、tty 與 sudoers 狀態。日誌格式相同，
status / tail 探測也一樣可用。

Fabric 需要分開的 `local()` 與 `run()` 兩條程式路徑。

### 9. Pager / TTY 強化

對 chezmoi 命令使用 `--no-pager` + `PAGER=cat GIT_PAGER=cat` + **不分配 PTY**
（[fleet_apply.py:293–299](../../scripts/fleet_apply.py#L293)）。可防範：

- `bat` 在 stdout 不是終端機時因為缺主題而崩潰。
- `less` 永遠卡住等使用者輸入。
- chezmoi 讀自己的 `pager` 設定鍵（會忽略 `PAGER` 環境變數——這就是必須加 `--no-pager` 的原因）。

這些都是這個機隊 (fleet) 上實際遇過的失敗；fabfile 那個年代用的是普通 `apt-get`，所以從沒踩到。

### 10. 分支 / topic-branch 工作流

`--branch BRANCH [--force-checkout]` 會在套用前於遠端原始碼目錄 (source dir) 切出 (check out) 一個功能分支。
Fabric 沒有「每台主機上的 dotfiles 倉庫各自有自己 checkout」這個概念。

## Fabric 做得比較好的地方

為了公平起見：

- **建置成本**：`pip install fabric && fab task`——不用 asyncio、不用 Rich、不用 TOML schema。fleet_apply.py 是一份 1200 行、能 uv self-installing 的腳本。
- **命令式 DSL**：Fabric 讓你直接內嵌寫 `sudo("apt install foo"); put("local.conf", "/etc/foo.conf"); run("systemctl restart foo")`。fleet_apply.py 只執行**一個**命令（`chezmoi update`/`apply`/`diff`），因為每台主機的具體邏輯是委派給 chezmoi + ansible 的。如果你想要臨時即興地 ssh fan-out，Fabric（或它的現代後繼者 [Fabric 2.x](https://www.fabfile.org/) / `pyinfra`）仍然是較合適的選擇。
- **抽象層較低 = 學習成本較低**：`fab -H host1,host2 -- uname -a` 可以開箱即用。fleet_apply.py 需要一份 TOML 檔加上 chezmoi 設定。

## TL;DR

| | Fabric 年代 (2018) | fleet_apply.py（現在） |
|---|---|---|
| 解決的問題 | 把命令推送到 N 台主機 | 把命令推送到 N 台主機 |
| 並行性 | 執行緒池 | asyncio 協程 |
| 崩潰復原 | 沒有——終端機沒了，整輪就沒了 | 遠端 logs + 哨兵 + `--tail` / `--status` / `--kill-orphans` |
| Sudo | 每次呼叫都 expect | 每台主機寫入一次檔案 + 共享 session |
| UI | 交錯的 stdout | Rich 即時表格 |
| 失敗語意 | rc != 0 = 失敗 | 當符合 chezmoi-skip pattern 時，rc != 0 會降級為 `drift` |
| 機密來源 | 程式碼內明文 | plain / prompt / bitwarden / none |
| 本地主機 | 獨立的 `local()` API | 同一份程式路徑（`local = true`） |
| 程式碼行數 | ~200 | ~1500 |

DNA 是相同的。新版本是「你讓一個工具累積七年『嗯，這上週又咬到我』修正」之後的樣子。
