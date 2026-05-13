# Fleet apply —— 多主機 `chezmoi update` 協調器 (orchestrator)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> **TL;DR** —— `just fleet-apply` 會在 `~/.config/fleet/machines.toml`
> 列出的每一台主機上平行執行 `chezmoi update --init`，並可選擇性地透過
> 明文 / 互動式提示 / Bitwarden CLI 注入 sudo 密碼。每主機 (per-host) 日誌
> 會落在 `logs/fleet-apply/<UTC-timestamp>/<host>.log`，
> 程序會以「失敗主機數」作為 exit code（最高封頂 125）。

實作：[`scripts/fleet/apply.py`](../../scripts/fleet/apply.py)
（uv inline-script：`asyncssh` + `tyro` + `rich`）。

另見：[fleet-apply-vs-fabric.md](fleet-apply-vs-fabric.md)，那是與作者
2018 年代 RaspPi-Cluster `fabfile.py` 的考古比較——同樣形狀的問題，
~7 年的營運教訓編碼進當前的實作裡。

## 何時該用

你在工作站上編輯了 dotfiles、推送到倉庫的 git 遠端，
現在想要每台筆電 / VM / 實驗室機器都拿到這個變更，
而不必逐一 ssh 進去手動輸入 sudo 密碼。

## 何時**不**該用

- 這個工具**不會**推送 dotfiles 倉庫本身——每個遠端跑的是
  `chezmoi update`，它會在遠端的原始碼目錄 (source dir) 上做 `git pull`。
  你的變更必須已經能被遠端取得（請先 push 到 GitHub / 你的內部 git 主機）。
- 它不會在遠端跑 `just upgrade-*`。那是另一個關注點；本工具僅限於 chezmoi apply。
- 它不會建置 (provision) 新主機。每個遠端必須已安裝 `chezmoi`，且至少完成過一次 `chezmoi init`。

## 清冊 (inventory) 檔

路徑：`~/.config/fleet/machines.toml`。chezmoi 從
[`dot_config/fleet/create_private_machines.toml.tmpl`](../../dot_config/fleet/create_private_machines.toml.tmpl)
**只播種一次**。`create_private_` 前綴的意思是：

- `create_` → chezmoi 會在第一次 apply 時播種此檔，之後永不再動它。每次 `chezmoi apply` 你的編輯都會被保留。
- `private_` → 檔案權限為 0600。可以安全地把明文 sudo 密碼放在這裡。
- 重置種子：`rm ~/.config/fleet/machines.toml && chezmoi apply`。

### Schema

```toml
[defaults]                    # 合併進每一台主機（host 鍵會覆蓋）
chezmoi_path    = "chezmoi"   # PATH 上的二進位檔；若 no-root 可填 "~/.local/bin/chezmoi"
connect_timeout = 15
command_timeout = 1800

[[hosts]]
name            = "lab-box"   # required，唯一的顯示名稱
ssh_alias       = "lab-box"   # 推薦：對應 ~/.ssh/config 中的 `Host lab-box`
# 或是顯式連線設定（在沒有 ssh_alias 時使用）：
hostname        = "203.0.113.42"
user            = "dwlee"
port            = 22
identity_file   = "~/.ssh/id_ed25519"

no_root_machine = false       # 必須與該遠端在 chezmoi init 時所用的 noRoot=
                              # 值一致（見下文）
chezmoi_path    = "chezmoi"   # 以 host 為單位覆蓋 defaults
local           = false       # 設 true 表示在本機執行 chezmoi（不走 SSH）；
                              # 見下文「Local host execution」節
extra_env       = { FOO = "bar" }   # 給遠端 chezmoi 執行的額外環境變數

password_source = { type = "...", ... }   # 見下文「Password sources」
```

### 密碼來源 (Password sources)

| `type` | 額外的鍵 | 行為 |
|---|---|---|
| `none`（預設） | — | 不注入密碼。適合 `no_root_machine = true` 的主機。 |
| `plain` | `value = "..."` | 直接從 TOML 讀取。倚賴檔案 0600 權限。 |
| `prompt` | — | 啟動時呼叫一次 `getpass()`，永不寫到磁碟。 |
| `bitwarden` | `item = "ssh-host-sudo"` | 啟動時跑 `bw get password <item>`。需要先 `bw unlock` + 匯出 `BW_SESSION`。 |

### `no_root_machine` 的語意

這個 flag 是用來**描述**遠端，不會去改變遠端。每個遠端在
`chezmoi init` 時設定了一個 `noRoot` 布林值
（見 [`.chezmoi.toml.tmpl:48`](../../.chezmoi.toml.tmpl)），
這個值已經寫入該機器的 `~/.config/chezmoi/chezmoi.toml`。

- 對於遠端 `noRoot = true` 的主機，設 `no_root_machine = true` ——
  fleet_apply 完全跳過 sudo（不寫密碼檔，run-scripts 的
  `sudo_session_init` 會走「non-interactive」分支並跳過 sudo 工作）。
- 對於遠端 `noRoot = false` 的主機，設 `no_root_machine = false`。

## sudo 密碼如何到達遠端

`scripts/fleet/apply.py` **不會**把密碼回顯到命令列上。
遠端命令（由 `build_remote_command()` 組裝）會把 stdin 讀進
`~/.cache/chezmoi-fleet/sudo.pass`（mode 0600，`umask 077`），
匯出 `CHEZMOI_SUDO_PASSWORD_FILE=$PWD/.cache/chezmoi-fleet/sudo.pass`，
跑 `chezmoi update`，然後 `trap … EXIT` 移除該檔案（即使崩潰也會）。

在遠端，`scripts/lib/sudo_shared.sh::sudo_session_init` 多了一條
非互動式注入路徑：當 `CHEZMOI_SUDO_PASSWORD_FILE` 指向一個可讀的檔案時，
密碼會以 `sudo -S -v` 驗證，然後採用到共享狀態目錄
（`$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/`）——和互動式 prompt 完全相同的流程，
包括看門狗 (watchdog) 會持續維持 sudo timestamp 的熱度，並寫出
`ansible-become.yml` 給 ansible roles 用。**同一次 `chezmoi update` 內後續的
run-scripts 都會看到這份快取狀態，再也不會重新 prompt。**

密碼檔生命週期：

- `~/.cache/chezmoi-fleet/sudo.pass` 是協調器的投放點；當 chezmoi 結束時由 SSH 命令的 `trap` 移除。
- `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/sudo.pass` 是由 `sudo_shared.sh` 管理的共享狀態目錄；當父執行的 `chezmoi` PID 結束時，由現有的看門狗清理。

## 連線：ssh_config 別名 vs 顯式設定

`asyncssh.connect(host=...)` 會像 OpenSSH client 一樣讀 `~/.ssh/config`。
建議優先使用 `ssh_alias`：

```
# ~/.ssh/config
Host lab-box
    HostName 10.0.0.42
    User dwlee
    ProxyJump bastion
    IdentityAgent ~/.1password/agent.sock     # 1Password SSH agent
```

```toml
# machines.toml
[[hosts]]
name      = "lab-box"
ssh_alias = "lab-box"          # ← 繼承上面所有設定，包括 ProxyJump
```

如果某台主機沒有 ssh_config 條目，回退到顯式的
`hostname` / `user` / `port` / `identity_file`。

## 本機執行 (`local = true`)

要把協調器自己也納入 fleet chezmoi apply，加一個 `local = true` 的主機：

```toml
[[hosts]]
name            = "self"
local           = true
no_root_machine = true   # 若你的本機 apply 需要 sudo 就設為 false
```

本機主機完全跳過 asyncssh —— chezmoi 以直接子程序執行
（`asyncio.create_subprocess_exec`），繼承協調器的 PATH、sudoers 狀態與 tty。
不使用 sudo 密碼注入；如果 chezmoi 需要 root，它會在父終端機上 prompt。
`kill-orphans` 子指令也會略過本機主機（從同一個 shell session 殺掉本地的
chezmoi 程序會把 `fleet_apply` 自己也一起殺掉）。其他所有功能 ——
日誌檔、即時表格、`--force`、`--keep-going`、`--command-timeout`、
並行性 —— 全部相同方式運作。

當 `local = true` 時，`ssh_alias`、`hostname`、`user`、`port`、
`identity_file` 都會被忽略。`chezmoi_path = "auto"` 仍然可用（子程序繼承
呼叫 shell 的 PATH，這也是協調器自身找到 `chezmoi` 的地方）。

## 命令

```bash
just fleet-apply                                # 平行，全部主機，update --init
just fleet-apply-dry-run                        # 改用 `chezmoi diff` 而不是 update
just fleet-apply-one lab-box                    # 單一主機，--serial 模式
just fleet-apply --hosts lab-box,vps-tokyo      # 子集
just fleet-apply --exclude throwaway-vm         # 全部除了
just fleet-apply --max-parallel 3               # 節流 (throttle) SSH 分派
just fleet-apply --no-init                      # `chezmoi apply`（跳過 update）
just fleet-apply --serial                       # 一次一台，無即時表格
just fleet-apply --command-timeout 600          # 對「熱 (warm) 機隊」設較緊的 timeout
just fleet-apply-kill                           # 殺掉每台主機上的孤兒 chezmoi/ansible
```

### Vibe-loop recipes（快速迭代）

```bash
just fleet-diff lab-box                         # 對單一主機跑 `chezmoi diff`，serial 輸出
just fleet-apply-file .zshrc                    # 對整個機隊套用單一檔案，跳過 ansible
just fleet-apply-file .config/zsh/aliases.zsh --hosts lab-box
just fleet-apply-branch feature/new-tmux        # 把遠端固定到一個分支（ff-only）
just fleet-apply-branch-force feature/new-tmux  # … 允許 `git reset --hard`（rebase 後）
```

`fleet-apply-file PATH` 是這條 vibe-loop 的招牌指令：

- 跳過 `chezmoi update`（因此也跳過慢的 `run_*` 腳本：ansible、Brewfile、Linuxbrew refresh）。
- 在 `chezmoi apply --exclude=scripts <PATH>` 重新渲染那單一目標前，先跑 `git -C $(chezmoi source-path) pull --ff-only`，讓遠端 checkout 拿到你最新的 commit。
- PATH 是 chezmoi 的 *target* 路徑（相對於 `$HOME`），例如 `.zshrc`、`.config/tmux/tmux.conf`、`.gitconfig`。**不是** `dot_zshrc` 那樣的 source 路徑。
- 在熱機隊上每台主機通常 ~5–15 秒就跑完一輪，相對於完整 `fleet-apply` 的 5–30 分鐘。
- 你還是得先 `git push` —— 遠端會在它的 checkout 上跑 `git pull`。本機主機（`local = true`）會跳過 pull，因為 source 就是你編輯器的 working tree。
- 漂移 / `--force` 語意不變：如果你也在遠端手動編輯過該檔，想覆寫的話請傳 `--force`。

`fleet-apply-branch BRANCH` 讓你能在功能分支上迭代，不汙染 `main`：

- 每個遠端在 `chezmoi apply` 之前會跑 `git fetch origin BRANCH && git checkout -B BRANCH origin/BRANCH && git merge --ff-only origin/BRANCH`。
- 模式被強制為 `apply`（因為 `chezmoi update` 會重新 pull `main`，把 checkout 給撤掉）。
- 預設合併是 `--ff-only`：若遠端 checkout 有分歧 (divergence) 會大聲失敗。請改用 `fleet-apply-branch-force`（會加上 `--force-checkout`）以改用 `git reset --hard origin/BRANCH` —— 在你 force-push 過 rebase 過的 topic branch 之後是必要的。
- 本機主機完全忽略 `--branch`：它們的 source dir 就是你的 working tree，從你編輯器底下切換它會很惡劣。略過會被記錄到日誌中。
- 與 `--apply-only-path` 組合可以得到最快的迴圈：`just fleet-apply --branch tmp/test --apply-only-path .config/foo/bar.toml --hosts lab-box`。


## 衝突處理：`--force` vs `--keep-going`

當遠端某個檔案已經漂移到不是 chezmoi 上次寫的內容（有人直接在主機上編輯過），
chezmoi 通常會在 `/dev/tty` 上 prompt 詢問是否要覆寫。fleet_apply 跑時沒有 PTY，
所以該 prompt 會以 `chezmoi: <file>: could not open a new TTY: open
/dev/tty: no such device or address` 死掉。有兩個 flag 控制反應：

| Flag | 預設 | 對衝突檔案的影響 | 對其餘 apply 的影響 |
|---|---|---|---|
| `--keep-going` / `--no-keep-going` | **on** | 保持**原樣**（不覆寫） | 繼續 —— 其他檔案仍會套用 |
| `--force` / `--no-force` | **off** | **覆寫**為 template 渲染結果 | 同上 |

預設組合（`--keep-going`、不含 `--force`）= **非破壞性**：
所有乾淨的檔案都套用，漂移的檔案被略過。fleet_apply 會解析 chezmoi 的 stderr；
如果該主機的*唯一*失敗是一或多個漂移目標上的「could not open a new TTY」，
它會把該主機歸類為 **`drift`**（黃色 `⚠`）而**非** **`failed`**（紅色 `✗`）。
摘要會列出每台主機的漂移檔案，讓你確切知道需要關注什麼：

```
Summary: 5 hosts, 3 ok, 1 failed, 1 drift, 0 skipped
  ✗ david_ubuntu  rc=1  log=…/david_ubuntu.log     # real failure
  ⚠ hanru_mac     drift in: .config/foo.toml       # only a drift skip
                  log=…/hanru_mac.log
                  (resolve: --force, or sync edits back to source)
```

漂移主機**不會**計入 process exit code —— 只有 `failed` 主機會。
這是有意的：drift 是「之後再處理」的訊號，不是 CI 失敗。
如果一台主機**同時**有 drift skip 與一個無關的錯誤
（ansible task、網路 timeout 等），它會被歸類為 `failed` 而非 `drift`，
這樣真正的錯誤永遠不會被默默降級。

要解決漂移，可以：

- 把漂移的內容遷移到一個逐機器 (per-machine) 覆寫檔（例如 `~/.gitconfig.local`，見下文），然後重跑。
- 或跑一次 `just fleet-apply --force` 讓正規 (canonical) template 勝出（也接受 `--hosts <name>` 限定範圍）。
- 或，對於你已經拿定主意的單一檔案，ssh 進去直接跑 `chezmoi apply --force <relpath>` —— 當 template 是對的、目標是過期時，這是最快的修法。

## 逐機器 git 覆寫 (`~/.gitconfig.local`)

`.gitconfig` 上常見的漂移是「該機器專屬的、合理只屬於那一台」的 git 設定 ——
`[safe] directory = /mnt/NAS/...`（host 掛載的 NAS）、
`[credential "https://gitlab.com"]`（glab CLI helper）、
`[http] proxy = ...`（公司 proxy）等等。
把這些放進由 chezmoi 管理的 `dot_gitconfig.tmpl` 是錯的（其他主機不適用）；
逐台手動編輯到遠端也會失敗，因為每次 fleet chezmoi apply 都會觸發
「drifted from template」的 prompt。

因此 `dot_gitconfig.tmpl` 的結尾是：

```gitconfig
[include]
    path = ~/.gitconfig.local
```

當該檔不存在時，`include.path` 會被 git 默默略過（不報錯），
所以沒有覆寫的機器不受影響。`~/.gitconfig.local` 已被 chezmoi 透過
`.chezmoiignore` 忽略 —— chezmoi 永遠不會去播種、覆寫、diff 它。
這和 `~/.zshrc.adhoc` 用於 shell 客製化是同一種「自我管理」pattern。

要遷移已經在某遠端漂移的 per-host 行：

```bash
ssh <host> 'chezmoi --no-pager diff .gitconfig'   # 看一下哪邊分歧了
ssh <host> bash -s <<'EOF'
  # 把 host 專屬區塊從受管檔案搬出來：
  # （手動將 ~/.gitconfig 中的 [safe] / [credential] / [http] 區段
  #   用你慣用的編輯器複製到 ~/.gitconfig.local）
  ${EDITOR:-vi} ~/.gitconfig.local
  ${EDITOR:-vi} ~/.gitconfig         # 刪除已遷移的行
EOF
just fleet-apply-one <host>                       # 現在應該乾淨了
```

## Timeouts

| Flag | 預設 | 理由 |
|---|---|---|
| `--connect-timeout` | 30 s | SSH banner + auth 握手。對高延遲或多 relay 的主機可調高。 |
| `--command-timeout` | 7200 s（2 小時） | 寬裕地涵蓋首次 apply：Linuxbrew 安裝（10–20 分鐘）+ 22 個 ansible roles + Brewfile cask 下載（GUI 應用程式；慢線路上可能 20+ 分鐘）+ python_uv_tools / npm / cargo bootstrap。當你的機隊過了首次 run，可降到例如 `--command-timeout 600`（10 分鐘）—— 熱機器穩態 (steady-state) 的重新套用通常 1–5 分鐘就完成。 |

如果 `--command-timeout` 觸發，協調器會透過 SSH channel 送 SIGTERM
**同時**關閉 channel（這會把 SIGHUP 送到遠端 shell，由包裝 (wrapper) 的
trap 傳遞給 chezmoi）。遠端應該會在幾秒內完全結束。

### 當某台主機卡住

`command_timeout` 是**外層**預算 —— 它會在超過時殺掉整個 chezmoi+ansible 鏈。
Ansible 本身**沒有逐 task 的 timeout**，所以一個卡住的 `npm install`、
`apt update` 重試迴圈，或對著慢的 mirror 跑的 `git clone`，
若你不管它，會把整個 2 小時預算燒掉。

典型的卡住症狀：

- `--status` 顯示該主機為 `running pids=...` 持續數十分鐘
- `--tail HOST` 日誌停在某個 `[N] TASK · …` 行不再前進
- 鑽進遠端：`ssh HOST pstree -p $PID` 在葉節點顯示 `python3 → /bin/sh -c "… npm install …"`（或 apt / git / cargo 等等價物）

復原流程：

1. **辨識卡住的 task**：用 `--tail HOST`（最後可見的 TASK 編號）以及 `ssh HOST pstree` 確認葉子程序。
2. **殺掉這次 run**：`just fleet-apply-kill --hosts HOST` —— 廣播 `pkill -TERM` 然後 `-KILL` 給 chezmoi/ansible/孤兒。
3. **限制下次嘗試的上限**：用 `--command-timeout 600`（或對穩態而言合理的值）重跑，這樣再次發生時就不會再燒掉 2 小時。
4. **如果同一個 task 一直卡**：那是 ansible role / 網路問題，不是 fleet-apply 的 bug。在 `dot_ansible/roles/<role>/tasks/main.yml` 中對該 task 加上 `timeout: 300` 或 `async: 600 poll: 30`。

`--status` 中的 `abandoned` 狀態（紅色，「no sentinel — wrapper SIGKILL'd?」）
意味著前一次 run 異常死亡 —— 包裝 shell 在 trap 來不及寫 exit 哨兵之前就被 SIGKILL 了。
常見成因：父程序被 OOM kill、手動 `kill -9`、或 process-tree 從卡住的子程序連鎖崩塌。
把它當成「沒留下復原麵包屑的失敗」即可。

## 殺孤兒、查狀態、重新接上

本地 Ctrl+C、網路中斷、筆電睡眠，或任何其他過早斷線，三種方式各自處理：

1. **In-band 清理**：`build_remote_command()` 把 chezmoi 包在一個 shell wrapper 中，
   並設 `trap '… pkill -TERM -P $_cz_pid …' INT TERM HUP`。asyncssh 用
   `request_pty='force'`，所以 SSH channel 關閉時會把 SIGHUP 送達遠端的 wrapper shell ——
   chezmoi（以及任何 ansible-playbook 子程序）會收到 SIGTERM，wrapper 再把 exit code 代回。
   實務上只要 asyncssh 真的關閉 channel（多數情況都會，包括協調器上的正常 SIGINT），這條就會觸發。

2. **Out-of-band 救援**：如果連 in-band trap 都沒觸發（例如 `kill -9` `scripts/fleet/apply.py`，
   或 asyncssh「乾淨地」關閉 channel 而沒有送出 HUP），遠端的 chezmoi/ansible 可能還在跑：

   ```bash
   just fleet-apply-kill                       # 全部主機
   just fleet-apply-kill --hosts lab-box       # 指定主機
   ```

   這會連線到每台主機，跑 `pkill -TERM -u "$(id -un)" -x chezmoi`，
   接著 `pkill -TERM -x ansible-playbook` 與 `ansible`，等 1 秒後對任何還活著的東西送 SIGKILL。
   不會送出 chezmoi 命令，所以任何時候機隊看起來「卡住」都可以放心執行。

3. **狀態探測 + 即時 tail 重新接上**（在觀察到 asyncssh + 筆電端緩慢的 kill
   有時會讓遠端工作默默繼續跑很多分鐘之後加入）：

   ```bash
   just fleet-apply-status                     # 哪些主機還在忙？
   just fleet-apply-status --hosts ts_nas      # 單一主機
   just fleet-apply-watch                      # 每 10 秒輪詢一次直到 idle
   just fleet-apply-tail jingle207             # 跟隨此主機最新的 run
   just fleet-apply-tail jingle207:20260422T140446Z
                                               # 指定一個 run id
   ```

   每次遠端 run 會把 chezmoi 合併的 stdout/stderr 透過 tee 寫入
   `~/.cache/chezmoi-fleet/logs/<run_id>.log`，並在 run 結束時放下一個
   含最終 exit code 的 `<run_id>.exit` 哨兵檔。`--status` 會兩者都讀：
   每台主機顯示 `running`（即時 PIDs + 數字）、`finished`（含 exit code）或 `idle`，
   並內嵌最近 5 行的最新日誌方便快速看上下文。
   `--tail` 會在新的 SSH session 上對日誌 `tail -F`，當哨兵出現時乾淨退出
   （或你 Ctrl+C 觀看者也行 —— 遠端 run 會繼續跑）。

   `--watch N`（或 `just fleet-apply-watch`，預設 N=10）會每 N 秒重複 `--status`，
   直到每台主機都回報 finished/idle，然後以 0 退出。把它當成殺掉協調器後
   被動的「等機隊 settle」游標 —— 不必一直按 ↑↩ 重新輪詢。
   後續輪詢會抑制 per-host 日誌 tail，讓輸出更精簡。

   **Self / `local = true` 主機**在這裡是一級公民：它們的日誌落在
   協調器自己的 `~/.cache/chezmoi-fleet/logs/`（同一個目錄，無 SSH 來回）。
   `--status` 與 `--tail self` 的運作和 SSH 主機相同。PID 過濾器會排除
   probe 自己以及它的父程序，這樣 `--status` 不會看到自己。

   兩個 probe 都是唯讀的：永遠不會送 chezmoi 命令、也不會殺任何東西。
   如果你決定要停下遠端工作，請與 `fleet-apply-kill` 搭配。

### 日誌保留

每個 per-host log 目錄會保留**最近 10 次** run（`.log` + `.exit` 一對）；
更舊的 pair 會在下次 run 結束時被刪除。可用 `--keep-logs N` 覆寫
（`N=0` 會完全停用 GC，如果你想永久累積 —— 需要自己定期
`rm -rf ~/.cache/chezmoi-fleet/logs`）。GC 發生在哨兵寫入**之後**，
所以剛剛結束的 run 永遠在保留視窗內。

## Exit codes

| Exit | 意義 |
|---|---|
| 0 | 所有被選中的主機都以 rc 0 完成 `chezmoi update`，或只有可復原的 drift skips（state = `drift`） |
| `N`（1–125） | `N` 台主機真的失敗了（rc != 0 含**非** drift skip 的錯誤、SSH 錯誤、timeout，或因為缺 sudo 密碼被略過） |
| 125 | 失敗主機超過 125（被封頂） |
| 2 | 設定錯誤（缺 TOML、schema 不合法） |

`drift` 主機刻意**不**計為失敗 —— 見上面「衝突處理」。它們在摘要中以 `⚠` 出現，
讓人類注意到，但只要沒有真正的錯誤，CI / cron 迴圈會持續通過。

## 日誌

每主機的日誌檔：`logs/fleet-apply/<UTC-timestamp>/<host>.log`。
每一行會以 `[out]` 或 `[err]` 加上前綴。前兩行紀錄主機詮釋資料以及
所送出的**字面 (literal)** 遠端命令（其中不含密碼 —— 只有把 stdin
pipe 進密碼檔的那段 shell）。

`logs/` **不在** `.chezmoiignore.tmpl` 中，因為它只在你從倉庫內執行
`just fleet-apply` 時存在於原始碼倉庫。請把它加進你本地的 `.gitignore`（如果你
還沒為 build artifacts 準備一份的話）。

## 疑難排解

- **`zsh:1: command not found: chezmoi` / rc=127** —— 非互動式的 SSH
  shell 不會 source `~/.zshrc`，所以 `~/.local/bin`（或你套件管理器
  把 chezmoi 放的地方）不在 PATH 上。預設的
  `chezmoi_path = "auto"` 已經會在呼叫 chezmoi 之前把 PATH 補上
  `~/.local/bin`、`~/bin`、`/opt/homebrew/bin`、
  `/home/linuxbrew/.linuxbrew/bin`、`/usr/local/bin`、`/snap/bin` ——
  涵蓋幾乎所有安裝。如果你的二進位檔在別處，請顯式指定：
  ```toml
  [[hosts]]
  name         = "weird-box"
  chezmoi_path = "/opt/custom/bin/chezmoi"
  ```
  跑 `ssh <host> command -v chezmoi`（互動式）vs
  `ssh <host> 'command -v chezmoi'`（非互動式）來看落差。
- **`chezmoi: <file>: could not open a new TTY: open /dev/tty: no such device or address`** ——
  該檔案在遠端漂移了，chezmoi 嘗試 prompt。在預設 `--keep-going` 下，
  該檔案保持不動，apply 的其餘部分會繼續（主機仍報告 rc!=0，所以 drift 是可見的）。
  解決流程見 [Conflict handling](#conflict-handling---force-vs---keep-going)；
  特別是針對 `.gitconfig`，請把 per-host 行遷移到
  [`~/.gitconfig.local`](#per-machine-git-overrides-gitconfiglocal)
  而非使用 `--force`。
- **`bw get password` 失敗** —— 跑 `bw unlock`，然後 `export BW_SESSION=...`。
- **`asyncssh.PermissionDenied`** —— 別名解析成功但驗證失敗。
  先用 `ssh <alias> echo ok` 測試；若你使用 1Password agent，
  請確認 ssh_config 中設了 `IdentityAgent` 而且 agent 已解鎖。
- **首次連線主機被「Host key verification failed」拒絕** ——
  fleet_apply 使用 `known_hosts=None`（= 跳過自己的檢查，交給你的
  `~/.ssh/known_hosts`）。先手動跑一次 `ssh <alias>` 來 TOFU 該 key。
- **遠端 chezmoi 對 noRoot 問題 prompt 然後卡住** —— 該主機從未做過
  `chezmoi init`。SSH 進去互動式跑一次 `chezmoi init`。
- **`no_root_machine=false` 主機在 sudo 階段立即失敗** —— 協調器解析出來的
  密碼是錯的。遠端的 `sudo_shared.sh` 會在 stderr 上以明確訊息拒絕（會被擷取在 per-host log 中）。
- **主機在 `chezmoi diff` / `update` 期間永遠卡住** —— 通常是 chezmoi 啟動了
  它設定的 pager（`bat`、`delta`、`less`）並阻塞等終端輸入。fleet_apply
  已經對每次 chezmoi 呼叫傳 `--no-pager`，但若你新增了繞過 chezmoi pager
  處理的自訂 subcommand / hookScript，請用 `just fleet-apply-kill --hosts <host>` 殺孤兒，
  並檢查該 subcommand 是否含 pager / `read` 呼叫。
- **Ctrl+C 後 run 看起來死了** —— 當你 Ctrl+C 掉 `scripts/fleet/apply.py` 時，
  asyncio 會 cancel 每個 task，會呼叫 `proc.terminate()` 並關閉 SSH 連線。
  遠端 wrapper 的 trap 會接住產生的 SIGHUP，並對 chezmoi tree 送 SIGTERM。
  若還有東西活著，跑 `just fleet-apply-kill` 會對每台主機的 `chezmoi` /
  `ansible-playbook` / `ansible` 程序廣播 `pkill -TERM`（再 SIGKILL）。

## 相關文件

- [`docs/this_repo/sudo-session.md`](sudo-session.md) —— 完整的 `sudo_shared.sh`
  helper API，包括本工具仰賴的 `CHEZMOI_SUDO_PASSWORD_FILE` 環境變數注入路徑。
- [`docs/this_repo/upgrades.md`](upgrades.md) —— 要升級遠端的工具，
  ssh 進去那台主機跑 `just upgrade-all`。fleet_apply 刻意只限定於 chezmoi apply。
- [`AGENTS.md`](../../AGENTS.md) —— 倉庫不變量，包括為何
  `scripts/**` 在 `.chezmoiignore.tmpl` 中（這樣 `scripts/fleet/apply.py` 永遠不會
  被部署到 `$HOME`，只能從倉庫內執行）。
