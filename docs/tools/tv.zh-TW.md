# television (tv) 快速參考

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[television](https://github.com/alexpasmantier/television) — 極速 TUI 模糊比對 (fuzzy finder)，採可插拔的「頻道 (channel)」架構。

自訂頻道：`dot_config/television/cable/`（由 chezmoi 管理）

---

## 基本用法

```bash
tv                   # 開啟互動式選擇器 (picker)（預設頻道）
tv <channel>         # 開啟特定頻道，例如 tv sesh
tv list-channels     # 列出所有可用頻道
tv --help            # 列出所有 flag
```

從 tmux 中：`prefix + T` 以彈出視窗 (popup) 開啟 sesh 頻道（見 [tmux 整合](#tmux-integration)）。

---

## 社群頻道

tv 內建頻道套件管理員。安裝後執行一次（並定期執行以更新）：

```bash
tv update-channels
```

這會將 [社群維護的頻道](https://alexpasmantier.github.io/television/community/channels-unix) 下載到 `~/.config/television/cable/`。它會：

- **跳過**你系統上不滿足需求的頻道（例如 macOS 上的 `apt-packages`）
- **跳過**已存在的頻道（不會覆寫自訂頻道）
- 涵蓋 git、docker、k8s、brew、cargo、GitHub、sesh、tmux 等多項

值得注意的社群頻道：`sesh`、`git-branch`、`git-log`、`git-stash`、`git-diff`、`brew-packages`、`docker-containers`、`gh-issues`、`gh-prs`、`just-recipes`、`zoxide`、`zsh-history`、`env`、`dirs`、`files`、`text`。

---

## 自訂頻道

### `tools` 頻道

執行期解析 `~/.config/docs/tools/cli-tools.md`（透過 chezmoi 從 `dot_config/docs/tools/` 部署）。該 markdown 檔是單一真實來源 (source of truth) — 編輯它即可新增或更新工具。

以 `tv tools` 或在 tmux 中按 `prefix + U` 開啟。

| 按鍵 | 動作 (action) |
|-----|--------|
| `Enter` | 立即執行所選工具 |
| `Ctrl+/` | 切換預覽 (preview) 面板（tldr 或 `--help`） |

如要把指令呼叫貼到 shell buffer（對需要參數的工具會附帶尾隨空格），改用 fzf ZLE widget：在任何 zsh session 中按 **Alt+T**。

---

### `lan-devices` 頻道

模糊搜尋本地子網路上的裝置，含開放 port、MAC/廠商、主機名（rDNS + mDNS）、ping RTT、最後出現時戳。底層為 `~/.config/television/lan-scan.sh`，它會把結果遞增寫入 `~/.cache/tv/lan-devices.tsv`，並把每台主機的 nmap 細節寫入 `~/.cache/tv/lan-ports/<ip>.txt`。頻道使用 `watch = 2.0`，因此背景掃描進行的同時，列就會串流進選擇器（state 欄：`discovered` → `scanning` → `scanned`）。

以 `tv lan-devices` 開啟，或先用 `lanscan` shell alias 執行同步掃描。

**Sudo 受控含備援**：當免密 sudo 可用（`sudo -n true`）時，腳本使用 `arp-scan -lgq` 取得最豐富的 MAC/廠商資料。否則退回 `nmap -sn` ping sweep + OS ARP 快取（macOS 上 `arp -an`、Linux 上 `ip neigh`）。備援路徑的廠商查詢使用 nmap 的 `nmap-mac-prefixes` OUI 資料庫。

**來源循環**（`Ctrl+S`）：

| 來源 | 描述 |
|--------|-------------|
| All devices | 所有發現的主機，依 IP 排序（預設） |
| With open ports | 僅 port 數 ≥ 1 的列 |
| Fresh only | 過去 5 分鐘內出現的主機 |

**預覽循環**（`Ctrl+F`）：

1. 快取的 nmap 服務細節（快速，來自 `~/.cache/tv/lan-ports/<ip>.txt`）
2. 即時 `nmap -sV -Pn -F` 重掃（會阻塞，約 10–30 秒）
3. ARP + rDNS + mDNS + ping 詮釋資料

**鍵位綁定**（`Alt+` 命名空間避開 tmux/TV 衝突）：

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 在 execute 模式執行完整 `nmap -sV -A` |
| `Alt+R` | 重掃所選主機的 ports + reload |
| `Alt+F` | 重掃整個子網路（discover + ports）+ reload |
| `Alt+D` | 僅重新發現（不掃 port）+ reload |
| `Alt+S` | SSH 到所選主機 |
| `Alt+H` | 在系統瀏覽器開啟 `http://<ip>` |
| `Alt+C` | 清除掃描快取 + reload |
| `Ctrl+Y` | 複製 IP 到剪貼簿 (clipboard)（SSH 下使用 OSC 52） |

**快取佈局：**

```
~/.cache/tv/
├── lan-devices.tsv         # 每個裝置一列（被 tv 監看）
├── lan-ports/<ip>.txt      # 每台主機的 nmap -sV 輸出
├── lan-scan.log            # 掃描進度 log
└── lan-scan.lock/          # mutex 目錄（離開時移除）
```

需要 `nmap`；`rustscan` 與 `arp-scan` 在存在時會被使用（皆屬 `networking_tools` ansible role）。

---

### `logs` 頻道

模糊瀏覽機器上的 log 檔，附彩色預覽。以 `tv logs` 開啟。

來源檔：[`dot_config/television/cable/logs.toml.tmpl`](../../dot_config/television/cable/logs.toml.tmpl)（chezmoi 模板 — 下方的 journalctl 循環只在 Linux 渲染）。完整工具集寫法：[log-tools.md](log-tools.md)。

**來源循環**（`Ctrl+S`）：

1. `$PWD` 之下的專案本地 log — 透過 `fd -HI` 找出 `.log` / `.ndjson` / `.jsonl`
2. 使用者 + 系統 log 目錄 — `~/.cache/**/*.log`、macOS 上的 `~/Library/Logs`、`/var/log/*.log` / `syslog*` / `messages*`（僅可讀者）
3. **僅 Linux** — `journalctl --output=short-iso -n 2000` 顯示 systemd journal 近期行。在 macOS 上以模板排除，因為 journalctl 輸出行不是檔案路徑，預覽/Enter/Alt+T 動作無法處理（後續可做專門的 `tv journalctl` 頻道）。

**預覽循環**（`Ctrl+F`）：

1. 透過 [`tailspin`](https://github.com/bensadeh/tailspin) 的彩色 tail — `tail -n 500 FILE | tspin --print`；無 `tspin` 時退回原始 `tail`
2. 純 [`bat`](https://github.com/sharkdp/bat) 視圖 — `bat --style=plain --color=always --line-range=:500` 供無偏比較

**鍵位綁定：**

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 在 `lnav` 中開啟（退回 `ccze -A \| less -R`，再退回純 `less -R`） |
| `Alt+T` | 用 `tspin --follow` 跟隨（或舊版 tailspin 用 `tail -F \| tspin --print`） |
| `Alt+E` | 在 `$EDITOR` 中開啟 |
| `Ctrl+Y` | 複製檔案路徑到剪貼簿（SSH 下使用 OSC 52） |

需要 `fd`（屬 `base` ansible role）。Tailspin、lnav、ccze 屬於 `devtools`。

---

### `services` 頻道

跨平台模糊選擇器，支援 systemd 服務（Linux）與 launchd 工作（macOS），含 tailspin 彩色 log 預覽與 Alt 鍵的生命週期動作。以 `tv services` 開啟。

來源檔：[`dot_config/television/cable/services.toml.tmpl`](../../dot_config/television/cable/services.toml.tmpl)（chezmoi 模板 — Linux 與 macOS 取得不同的 `systemctl` vs `launchctl` 內容）。完整寫法含符號圖例與 sudo 注意事項：[services.md](services.md)。

**來源循環**（`Ctrl+S`）：

1. Running only — 啟用中的服務，system + user 合併
2. All loaded — 在執行期已知單元中的 active + inactive + failed
3. Failed only — 已當機 / 非零退出
4. User-scope only — `systemctl --user` / macOS `gui/$UID/` 網域
5. **Installed on-disk** — 磁碟上每個 unit 檔 / `.plist`，含啟用徽章（Linux 上 `✓ Enabled` / `○ Disabled` / `— Static` / `⊘ Masked`；macOS 上 `● Loaded` / `○ On-disk`）。這是「已設定但未啟用」的探索視圖 — 落在 `○ Disabled` 列上，按 `Alt+L`，搞定。

**預覽循環**（`Ctrl+F`）：

1. 透過 tailspin 的彩色 log tail — Linux 上 `journalctl -u NAME -n 500`；macOS 上 tail `launchctl print` 中的 `StdoutPath`（未設定 stdout 時印出有用訊息，而不是阻塞於 `log show`）。
2. 狀態 / 詳情 — `systemctl status` / `launchctl print`。

**鍵位綁定：**

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 跟隨即時 log（`journalctl -fu` / `tail -F StdoutPath \| tspin` 或 `log stream`） |
| `Alt+R` | Restart（scope=system 時自動加 sudo） |
| `Alt+S` | Stop（`systemctl stop` / `launchctl bootout`） |
| `Alt+T` | Start（`systemctl start` / `launchctl kickstart`，含 bootstrap-by-search 備援） |
| `Alt+U` | Reload（`reload-or-restart` / `launchctl kickstart`） |
| `Alt+D` | 在 pager 中顯示完整狀態 |
| `Alt+E` | 在 `$EDITOR` 中編輯 unit 檔 / plist |
| `Alt+L` | 切換開機自啟 |
| `Ctrl+Y` | 複製服務名稱到剪貼簿 |

當該列的 scope 欄為 `system` 時，所有變更類動作會自動前置 `sudo`。動作以 `execute` 模式執行，必要時可顯示 sudo 密碼提示。

更深入的平台特化頻道（`tv systemd` 含 timers/sockets/targets + mask/daemon-reload；`tv launchd` 含 plist-on-disk 來源 + bootstrap/bootout）為後續計畫 — 完整 roadmap 見 [`services.md`](services.md)。

無新依賴 — Linux 上使用 `systemctl`/`journalctl`（base systemd），Darwin 上使用 `launchctl`/`log`（macOS 內建），加上 `devtools` 中的 `tspin`。

---

### `ansible` 頻道

瀏覽 `dot_ansible/`（部署到 `~/.ansible/`）中提供的 ansible playbooks / roles / tags。適合快速跑 playbook、編輯後語法檢查，或複製完整的 `ansible-playbook` 呼叫貼到 shell。

以 `tv ansible` 開啟。

**來源循環**（`Ctrl+S`）：

| 來源 | 描述 |
|--------|-------------|
| Playbooks | `~/.ansible/playbooks/*.yml`（base、linux、macos） |
| Roles | `~/.ansible/roles/` 下每個 role 目錄 |
| Tags | 從所有 playbooks 萃取的唯一 tag 名稱 |

**預覽循環**（`Ctrl+F`）：

1. Playbook → 透過 `bat` 顯示 YAML；role → `tasks/main.yml` + `defaults/main.yml`；tag → 宣告該 tag 的 playbook 行
2. Playbook → 該檔內的 tag 列表；role → 目錄列表；tag → 引用該 tag 的 roles

**鍵位綁定**（`Alt+` 命名空間避開 tmux/TV 衝突）：

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 執行 playbook（`ansible-playbook playbooks/<name>.yml`）；對 role/tag，執行 OS 預設 playbook 並以 `--tags <name>` 過濾 |
| `Alt+C` | 語法檢查（`--syntax-check`） |
| `Alt+D` | Dry run（`--check`） |
| `Alt+T` | 執行 OS 預設 playbook，依所選 tag/role 過濾 |
| `Alt+E` | 在 `$EDITOR` 中編輯檔案（playbook YAML 或 role 的 `tasks/main.yml`） |
| `Alt+V` | 在 `yazi` 中開啟 role 目錄（僅 roles 來源） |
| `Ctrl+Y` / `Alt+Y` | 把完整 `ansible-playbook ...` 指令複製到剪貼簿（SSH 下用 OSC 52） |

所有動作皆 `cd ~/.ansible` 並 export `ANSIBLE_CONFIG=$HOME/.ansible/ansible.cfg`，比照 [`docs/this_repo/architecture.md`](../this_repo/architecture.md#ansible-usage) 中的手動呼叫模式。OS 預設：Darwin 為 `macos.yml`，其餘為 `linux.yml`。

---

### `git-ops` 頻道

模糊搜尋完整 VSCode Source Control + GitLens 指令選單（約 150 條：pull/push、commit 變體含 amend、undo-last-commit、branch、rebase、cherry-pick、stash、tags、worktrees、submodule、config）。底層為 `~/.config/docs/tools/git-ops.md` — 該 markdown 表格是單一真實來源；編輯該表格即可改變頻道。

每列同時顯示對應的 **oh-my-zsh `git` plugin alias**（`gc!`、`gcam`、`gpf!`、`gst`、`grhh`、`gstp` 等）或本 repo 的自訂 function（前綴 `*`，例如 `*gcam-amend`、`*gundo`、`*lg`）。意思是你可依語意名（`amend`、`undo`、`force push`）、完整 `git …` 呼叫，**或**你只記得一半的 alias 模糊搜尋 — 任一種都會落到同一列。

以 `tv git-ops` 獨立開啟，或在 zsh 中按 `Alt+I` 把所選指令直接貼進 shell 提示符。

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 把所選指令印到 stdout — 由 `Alt+I` ZLE widget 擷取並插入 `LBUFFER` |
| `Ctrl+Y` | 複製指令到剪貼簿（覆寫 TV 預設；pbcopy / wl-copy / xclip / OSC 52 備援） |
| `Alt+E` | 確認提示後 `eval` 該指令（y/N）；其他輸入預設取消 |
| `Ctrl+F` | 切換預覽：對應的 `git-ops.md` 列 ↔ `git help <subcommand>` |
| `Ctrl+O` | 切換預覽面板（TV 全域） |

> 使用 `Alt+E`（非 `Ctrl+E`）作為 execute，以保留 TV 全域 `Ctrl+E = go_to_input_end` 的肌肉記憶。

破壞性的列（`commit --amend`、`reset --hard`、`push --force`、`branch -D`、`clean -fd`、`stash drop/clear`、`tag -d` 對 remote、rebase 等）在顯示行上前綴 `⚠`，並在 `Alt+E` 下觸發紅色警告橫幅。

它能解決的使用情境：

- 「`git commit --amend --no-edit` 那個 flag 到底怎麼打？」 — 打 `amend` 或 `gcn!`，Enter，搞定。
- 「怎麼撤回上一次 commit 又不丟工作？」 — 打 `undo` 或 `gundo`，看到三種變體（soft / mixed / hard，連帶破壞性標記）。
- 「哪個 alias 是安全的 force push？」 — 打 `force`，看到 `gpf`（with-lease，安全）旁邊就是 `gpf!`（原始 `--force`，破壞性）。
- 把指令複製到 Cursor 對話或同事的 Slack 而不必打字 — `Ctrl+Y`。
- `git worktree`、`git submodule`、`git cherry-pick` — 那些沒人記得 flag 的指令。

新增指令：在 `dot_config/docs/tools/git-ops.md` 適當段落後追加一列：

```markdown
| Menu Label | `git some-command --flag` | `gsf` | Short description | destructive |
```

欄位為 `Menu | Command | Alias | Description | Notes`。若沒有 oh-my-zsh alias，alias 欄留空（`| |`）；若是新增住在 `dot_config/zsh/10_aliases.zsh` 的自訂 function，前綴用 `*`。完整 OMZ alias 參考見 `docs/zsh/aliases.md`。

重新跑 `chezmoi apply`（md 部署到 `~/.config/docs/tools/`）；不需 reload 頻道 — 它在執行期解析。

---

### `pueue` 頻道

[pueue](https://github.com/Nukesor/pueue) 的互動式工作管理器 — 模糊搜尋工作、預覽 log、不離開選擇器即可 pause/resume/kill/restart。在執行期解析 `pueue status --json`。需要 `pueue` 與 `jq`。

以 `tv pueue` 開啟。每 2 秒自動重整。

**來源循環**（`Ctrl+S`）：

| 來源 | 描述 |
|--------|-------------|
| All tasks | 所有工作，最新優先（預設） |
| Active only | Running + Queued + Paused 工作 |
| Failed only | 非零退出的工作 |
| Groups overview | Pueue groups 含狀態與並行度 |

**工作管理**（皆使用 `Alt+key` 以避開與 TV 內建及 tmux 衝突）：

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 跟隨執行中的工作 / 檢視已完成工作 log / 顯示 group 狀態 |
| `Alt+E` | 在 `$EDITOR` 編輯工作指令（僅 stashed/queued） |
| `Alt+P` | 暫停工作 |
| `Alt+R` | 恢復/啟動工作 |
| `Alt+K` | 殺掉工作 |
| `Alt+T` | 原地重啟工作 |
| `Alt+X` | 從清單移除工作 |
| `Alt+L` | 清掉所有已完成工作 |

**剪貼簿：**

| 按鍵 | 動作 |
|-----|--------|
| `Alt+Y` | 複製原始指令到剪貼簿 |
| `Alt+A` | 複製完整 `pueue add -w <path> -g <group> ...` 指令到剪貼簿 |

`Alt+Y` 只複製原始指令字串。`Alt+A` 重建一個完整可重現的 `pueue add` 呼叫，包含工作目錄、group、label、優先序、依賴 — 適合重新排隊或分享工作。

**Group 過濾：**

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 在 groups 視圖：顯示 `pueue status -g <name>` 文字總覽 |
| `Alt+G` | 開啟僅顯示所選工作之 group 的過濾視圖 |

`Alt+G` 從所選項目擷取 group 名稱並啟動新的 `tv` 實例，`--source-command` 過濾到該 group。過濾視圖有預覽但不含完整動作鍵位綁定。退出可回到主 `tv pueue` 頻道。在 groups 來源（循環 4）按 Enter 透過 `pueue status -g` 顯示快速文字總覽。

**預覽**（`Ctrl+F` 循環）：

1. 工作 log 輸出（`pueue log <id> --lines 200`） — 安裝 [tailspin](log-tools.md) 時透過 `tspin --print` 輸出彩色時戳/level/IP/URL。剛安裝完時退回原始輸出。
2. 完整 JSON 工作詳情（時間、依賴、結果 — env 已剝除以利閱讀）

**實作筆記：**

- 所有動作鍵位綁定使用 `Alt+`，避免遮蔽 TV 內建（`Ctrl+P`/`Ctrl+K` 為導覽、`Ctrl+A`/`Ctrl+E` 為輸入游標、`Ctrl+R` 為 reload 等）以及 tmux root-table 綁定（`C-h/j/k/l` 為 vim-tmux-navigator）。需要終端機把 Option 當 Meta 送（Ghostty：`macos-option-as-alt = left`）。
- 輸出格式使用 jq 的 `@tsv` — 避免與 jq 的 `\(...)` 插值語法的 TOML/shell 逸出衝突
- 剪貼簿動作跨平台：pbcopy（macOS）、wl-copy（Wayland）、xclip（X11），加上 OSC 52 備援用於遠端 SSH session（透過 `set-clipboard on` 的 tmux 也能運作）
- 在 pueue 頻道中覆寫 `Ctrl+Y` 以僅複製原始指令（TV 預設的 `ctrl-y` 會複製含 ID、狀態、group 的整個顯示行）
- `pueue edit` 僅對 stashed/queued 的工作有效（pueue 限制）；對執行中/已完成工作請用 `Alt+Y` 複製後手動重新加入

---

### `azure` 頻道

透過 `az` CLI 模糊搜尋 Azure 資源，含每資源動作：restart / start / power-off / deallocate / rotate-public-IP / SSH / open-in-portal / delete / copy-id / switch-subscription。底層為 `~/.config/television/` 下三支輔助腳本（`azure-source.sh`、`azure-preview.sh`、`azure-rotate-ip.sh`）。需要 `az`（ansible `iac_tools` tag）與 `jq`；不具備兩者的主機會自動跳過此頻道。

以 `tv azure` 開啟。無自動重整 — `az` 呼叫太慢不適合輪詢；按 `Ctrl+R` 重新載入。

**登入閘門：** 若 `az account show` 失敗，頻道會顯示單一合成列（`login · not-logged-in`）。按 `Enter` 執行 `az login`，再按 `Ctrl+R` 重新載入。

**來源循環**（`Ctrl+S`）：

| 來源 | 描述 |
|--------|-------------|
| Resource Groups | `az group list`（預設） |
| Virtual Machines | `az vm list -d` — 名稱、RG、location、power state |
| Public IPs | `az network public-ip list` — ipAddress + FQDN |
| NICs + NSGs | `az network nic list` 與 `az network nsg list` 的聯集 |
| All resources | `az resource list` — 知道名稱但不知類型時的通用備援 |

**預覽循環**（`Ctrl+F`）：

1. `az <kind> show -o yaml` 在可用時透過 `bat` 美化輸出
2. `az <kind> show -o json` 供複製貼上 / 透過 `jq` pipe

**鍵位綁定**（`Alt+` 命名空間避開 tmux/TV 衝突）：

| 按鍵 | 動作 | 適用於 |
|-----|--------|----------|
| `Enter` | 顯示完整資源（`az … show` execute 模式）；在 login 列上跑 `az login` | 所有 |
| `Alt+R` | Restart VM | vm |
| `Alt+S` | Start VM | vm |
| `Alt+P` | 關機（仍計費） | vm |
| `Alt+D` | Deallocate VM（不計費） | vm |
| `Alt+I` | **輪換 public IP** — 保留 FQDN，更換 IP | vm |
| `Alt+H` | 透過 `az ssh vm` SSH（需要 `ssh` az 擴充） | vm |
| `Alt+O` | 在 Azure Portal 開啟資源（`open` / `xdg-open` / `wslview`） | 所有 |
| `Alt+X` | 帶 y/N 確認的刪除 | rg / vm / pip / nic / nsg / res |
| `Alt+U` | 切換訂閱（fzf 選單列出 `az account list`） | 所有 |
| `Ctrl+Y` / `Alt+Y` | 複製資源 id 到剪貼簿（pbcopy / wl-copy / xclip / OSC 52 備援） | 所有 |

動作內部對該列的 kind 欄做 `case $kind`，所以錯型別的鍵（例如在 RG 列按 `Alt+R`）會印出 1 秒「only applies to VMs」提示並 no-op — 與 `ansible` 頻道的 role-only `Alt+V` 同樣的慣用法。

**輪換 Public IP**（`Alt+I`）呼叫 `~/.config/television/azure-rotate-ip.sh <rg> <vm>`，是 [`DockerCompose-V2Ray/scripts/az_rotate_ip.sh`](https://github.com/daviddwlee84/DockerCompose-V2Ray/blob/main/scripts/az_rotate_ip.sh) 的無狀態移植。它會：

- 透過 `az` 即時解析 VM → NIC → PIP → DNS label（無 `.secrets/` 狀態檔）。
- 在設定了 `SSH_CONNECTION` 時拒絕執行（卸下 PIP 會在重新接上前切斷 SSH session）。
- 需要 Standard SKU（Basic 已於 2025-09-30 退役）並設有 `dnsSettings.domainNameLabel` — 否則沒東西可保留。
- 5 步驟：detach → delete → 用相同 `--dns-name` recreate → reattach → 用 `dig +short <fqdn>` 驗證。
- `AZ_YES=1 azure-rotate-ip.sh <rg> <vm>` 會跳過確認提示（適合腳本化；TV 頻道以互動方式執行所以提示沒問題）。

使用情境：GFW 封鎖 Azure VM 的 public IP。輪換能保留 `*.cloudapp.azure.com` FQDN、TLS 憑證、客戶端設定，全都不變 — 唯一變動只是底層 IP。

**多訂閱：** `Alt+U` 把 `az account list` pipe 進 `fzf`，讓你不離開選擇器就能 `az account set`，然後重新載入來源。`[ui].input_header` 單純讀作 "Azure" — 在頻道初始化時解析目前訂閱很便宜，但在 `Alt+U` 後刷新它的 UX 複雜度不值得。

**v1 非目標：** 佈建（`az vm create` 留在 V2Ray repo）、超出 `Alt+X` 的拆除、Windows 特定 VM 操作。

---

### `clash` 與 `clash-api` 頻道

Clash 現以兩個 TV 頻道提供：

- `tv clash` — 以 YAML 為基礎瀏覽已解析的 Clash profile。
- `tv clash-api` — 即時瀏覽 external-controller API。

兩個頻道共用 `~/.config/television/` 下相同的輔助：

- `clash-parse.py` — 帶 `uv run --script` shebang 的 PyYAML 解析器。
- `clash-source.sh` — 對 YAML 與 API 兩種列同時提供 TSV 來源輸出。
- `clash-preview.sh` — YAML、API、latency、context 視圖的預覽分派器。

需要 `curl`（base role）。`uv` 在 YAML 解析時必要，純 env 驅動的 API 使用則為選用。`bat` 與 `jq` 為選用。

#### `tv clash`

以 `tv clash` 開啟。

**YAML 探索**（first match wins）：

1. `$CLASH_CONFIG` — 顯式覆寫，路徑不存在時硬性失敗。
2. `~/.config/clash/profiles/list.yml` → 啟用中的 `profiles/<time>.yml`
3. `~/.config/clash/config.{yaml,yml}`
4. `~/.config/mihomo/config.{yaml,yml}`
5. `~/Library/Application Support/{clash,mihomo}/config.{yaml,yml}`（macOS）

重要的分工是：

- YAML 列（`proxies`、`proxy-groups`、`rules`、`summary`、`server`、`path`）來自已解析的 profile，通常是啟用中的 `profiles/<time>.yml`。
- Controller 操作仍偏好來自即時 Clash 設定的執行期 `external-controller`，因為 profile 檔常保留陳舊的 controller port 如 `127.0.0.1:9090`，而執行中的 app 用的是不同的本機 port。

範例：

```bash
tv clash
CLASH_CONFIG="$HOME/.config/clash/profiles/1731944239843.yml" tv clash
```

若已解析的 YAML 沒有 `proxies[]`、`proxy-groups[]` 或 `rules[]`，頻道會發出單一資訊性 `none` 列，而不是 TV 通用的「no stdout」佔位文字。當完全沒有設定時，在 `none` 列按 `Enter` 仍會 seed `~/.config/clash/config.yaml` 並開啟 `$EDITOR`。

**來源循環**（`Ctrl+S`）：

| 來源 | 描述 |
|--------|-------------|
| Proxies | 每個 `proxies[]` 條目一列 — `name`、`type`、`server:port`、緊湊的 `tls/udp/network/cipher` flag |
| Proxy Groups | 每個 `proxy-groups[]` 條目一列 — `name`、`type`、目前第一個成員、`N members` |
| Rules | 每個 `rules[]` 條目一列，索引 `#NNNN` |
| Summary | 頂層 YAML scalar 加上 `proxies.count` / `proxy-groups.count` / `rules.count` |
| API | 透過 `/version`、執行期 `/configs`、`/connections` 計數的即時 controller 健康狀態 |

**預覽循環**（`Ctrl+F`）：

1. Main — 所選 YAML 區塊（API 列改顯示 controller JSON）
2. Latency — controller 可達時顯示 `/proxies/:name/delay`，否則退回 TCP + ping
3. Meta — YAML 情境：引用某 proxy 的 groups、group YAML、所選 rule、或 API 詳情

#### `tv clash-api`

以 `tv clash-api` 開啟。

Controller 探索：

1. `$CLASH_CONTROLLER` / `$CLASH_SECRET`
2. 來自本機 Clash 設定的執行期 `external-controller`

範例：

```bash
tv clash-api
CLASH_CONTROLLER=192.168.222.207:9090 tv clash-api
CLASH_CONTROLLER=192.168.222.207:9090 CLASH_SECRET=mytoken tv clash-api
```

`tv clash-api` 不在 UI 內加上主機切換。遠端目標刻意保持以 env 驅動。

**來源循環**（`Ctrl+S`）：

| 來源 | 描述 |
|--------|-------------|
| Proxies | 即時 `/proxies` 葉節點（不含 `all` 的列） |
| Proxy Groups | 即時 `/proxies` selector 風格條目（含 `all` 的列） |
| Rules | 即時 `/rules` 條目 |
| Summary | `/version`、`/configs`、`/connections` |

**預覽循環**（`Ctrl+F`）：

1. Main — 所選 proxy、group、rule 或 summary 列的 controller JSON
2. Latency — proxies 顯示 `/proxies/:name/delay`，groups 顯示 `/proxies/:group` 詳情
3. Meta — proxy-group 引用、group 成員/歷史、鄰近的 rules

**共用鍵位綁定**（`Alt+` 命名空間避開 tmux/TV 衝突）：

| 按鍵 | 動作 | 適用於 |
|-----|--------|------------|
| `Enter` | 顯示所選列的完整詳情 | 兩者 |
| `Alt+T` | Latency 測試 | 兩者 |
| `Alt+S` | 將 proxy-group 的選擇切換到所反白的 proxy | 兩者 |
| `Alt+C` | 關閉所有連線（`DELETE /connections`） | 兩者 |
| `Alt+R` | 重新載入 Clash 設定（`PUT /configs?force=true`） | 兩者 |
| `Alt+D` | 開啟 `http://<host>/ui`，否則退回 `yacd.haishan.me` | 兩者 |
| `Ctrl+Y` | YAML 能解析時複製 `server:port`，否則複製列名 | 兩者 |
| `Alt+Y` | 複製列名 | 兩者 |
| `Alt+E` | 在 `$EDITOR` 中編輯已解析的 YAML 設定 | 僅 `clash` |

注意事項：

- 所有變更類動作（`Alt+S/C/R`）會先探測 `/version`；無法觸及的 controller 會以清楚訊息 no-op。
- `tv clash-api` 只有當 `CLASH_CONFIG` 指向在該 controller 主機上有意義的設定路徑時，才能 reload 遠端 controller。如果遠端主機與本機執行期 controller 不同，且未提供顯式 `CLASH_CONFIG`，`Alt+R` 會以說明拒絕，而不是送出錯誤的本機路徑。

**遮蔽硬化**

使用者貼進 `.specstory/history/`、`.cursor/plans/`、`.claude/plans/`、`.opencode/plans/` 的範例設定常含 vmess UUID 與 Azure proxy 主機名。[`.gitleaks.toml`](../../.gitleaks.toml) 中三條規則以 `secretGroup = 1` 抓取它們，因此 `scripts/redact_secrets.py` 只重寫敏感 capture：

- `clash-vmess-uuid` — `uuid: 41871a7c-…` → `uuid: 418...c56`
- `clash-vmess-share-link` — `vmess://<base64>` → `vme...XYZ`
- `azure-cloudapp-hostname` — `<vm>.<region>.cloudapp.azure.com` → 截斷後僅保留 host

原始 IPv4 proxy server 預設刻意不遮蔽；它們相對於公共 DNS 與 CDN 端點的合法範例來說太雜訊了。

---

### `sesh` 頻道（社群）

由 `tv update-channels` 提供。在 session 類型與目錄搜尋間做來源循環，並含 connect/kill 動作。

**來源循環**（用 `Ctrl+S` 循環）：

| 來源 | 描述 |
|--------|-------------|
| All sessions | `sesh list --icons`（預設） |
| Tmux sessions | `sesh list -t --icons` |
| Configured sessions | `sesh list -c --icons` |
| Zoxide directories | `sesh list -z --icons` |
| File search | `fd -H -d 2 -t d -E .Trash ~` |

**動作鍵位綁定：**

| 按鍵 | 動作 |
|-----|--------|
| `Enter` | 連到所選 session |
| `Ctrl+D` | 殺掉所選 tmux session + 重整列表 |

**預覽：** `sesh preview` — 右側面板。

---

## Tmux 整合

| 綁定 | 動作 |
|---------|--------|
| `prefix + T` | 以 television 彈出視窗開啟 sesh 頻道 |
| `prefix + g` | 以 fzf 開啟 sesh session 選擇器（替代方案） |

> tmux session 管理鍵位的完整參考請見 `docs/tools/tmux/keybindings.md`。

---

## 與 tmux 的鍵位衝突

TV 預設的 `ctrl-h/j/k/l` 與 tmux `vim-tmux-navigator` root-table pane 導覽（`C-h/j/k/l`）衝突。受管設定（`dot_config/television/config.toml`）解法：

| 預設 | 動作 | 重新對應到 | 備註 |
|---------|--------|-------------|-------|
| `ctrl-j` | select_next_entry | _(移除)_ | 用 `down` 或 `ctrl-n` |
| `ctrl-k` | select_prev_entry | _(移除)_ | 用 `up` 或 `ctrl-p` |
| `ctrl-h` | toggle_help | `alt-h` | 助記符，無衝突 |
| `ctrl-l` | toggle_layout | `alt-l` | 在 pueue 頻道被覆寫（清除） |

其他 TV 預設（`ctrl-s`、`ctrl-f`、`ctrl-r`、`ctrl-y` 等）皆保留，因為不會與 tmux root-table 綁定衝突。

---

## 小技巧

- `Tab` / `Shift+Tab` — 在結果中導覽
- `Ctrl+P` / `Ctrl+N` — 上/下移動（vim 使用者）
- `Alt+H` — 切換說明面板（從 `ctrl-h` 重新對應以避開 tmux 衝突）
- 頻道定義為 `~/.config/television/cable/` 中的 `.toml` 檔
- 全域設定在 `~/.config/television/config.toml`（由 chezmoi 從 `dot_config/television/config.toml` 管理）
- 執行 `tv update-channels` 取得/更新社群頻道
- 本 repo 的自訂頻道住在 `dot_config/television/cable/`（透過 chezmoi 部署，不會被 `update-channels` 覆寫）
- 比較與頻道最佳實踐請見 [tv vs fzf](tv-vs-fzf.md)
