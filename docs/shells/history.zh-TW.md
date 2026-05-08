# Shell 歷史紀錄 (bash, zsh, atuin)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> **適用對象**：想知道自己的 shell 歷史實際存在哪裡、由哪些環境變數 / setopt
> 控制、如何在多使用者伺服器上檢視或清除它，以及 [atuin](../tools/atuin.md)
> 在這之中扮演什麼角色的人。atuin 的安裝設定與快捷鍵請見
> [tools/atuin.md](../tools/atuin.md)。

## TL;DR

| 問題 | 答案 |
|---|---|
| bash 把歷史存在哪？ | `~/.bash_history`（可用 `$HISTFILE` 覆寫）。預設只在 shell 結束時寫入，除非搭配 `shopt -s histappend` + `PROMPT_COMMAND` 強制 flush。 |
| zsh 把歷史存在哪？ | `~/.zsh_history`（可用 `$HISTFILE` 覆寫）。在 `setopt share_history`（OMZ 預設）下，每個指令會立即附加到檔案，並在其他存活的 session 下次提示時被重新讀入。 |
| 我們的 zsh 歷史上限是誰設的？ | **不是我們設的。** 本 repo 完全沒有設定 zsh 歷史選項，全部來自 oh-my-zsh 的 [`lib/history.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/history.zsh)：`HISTSIZE=50000`、`SAVEHIST=10000`，外加 `share_history` / `hist_ignore_dups` / `hist_ignore_space` / `hist_verify` / `extended_history` / `hist_expire_dups_first`。 |
| 我們的 bash 歷史上限是誰設的？ | [`dot_config/bash/02_history.bash`](../../dot_config/bash/02_history.bash)：`HISTSIZE=10000`、`HISTFILESIZE=20000`、`HISTCONTROL=ignoreboth`、`shopt -s histappend cmdhist`。 |
| root 能讀到其他使用者的歷史嗎？ | 通常可以（`/home/<user>/.{zsh,bash}_history`，預設權限為 `0600`），但內容**並不完整**——見 [多使用者稽核](#多使用者稽核-multi-user-audit)。atuin 的 SQLite 也是可讀的，雖然在傳輸時是加密的（但預設並非 at-rest 加密）。 |
| 歷史檔案的列數上限是多少？ | **沒有檔案層級的上限，只有筆數上限**：bash 在結束時把檔案截斷到 `$HISTFILESIZE` 行；zsh 在儲存時截斷到 `$SAVEHIST` 筆。atuin 預設**沒有筆數上限**——SQLite db 會永遠成長（指令很小；約 1MB / 10k 筆）。 |
| 怎麼真正把一個指令清乾淨？ | 見 [清除自己的歷史紀錄](#清除自己的歷史紀錄)——天真地用 `history -d N` 是不夠的；你必須同時 flush 到磁碟，而且如果有裝 atuin 也要從 atuin 刪除。 |

## Bash 歷史紀錄

### 儲存位置

- **檔案**：`$HISTFILE`，預設為 `~/.bash_history`。權限取決於檔案首次建立時
  你的 `umask`——通常是 `0600`（只有擁有者可讀寫）。在某些有強化過的 skel 的
  系統上可能是 `0644`——用 `stat -c %a ~/.bash_history` 檢查，如果 group/world
  可讀就用 `chmod 600` 改掉。
- **記憶體 ring**：每個互動式 bash 在 RAM 中持有自己的指令清單，上限為
  `$HISTSIZE` 筆。`history` 列出這個 ring；`fc -l` 是 POSIX 的等價寫法。
- **磁碟檔案上限**：`$HISTFILESIZE` 行。在 shell 結束時（或每次 `history -a`
  / `history -w`），bash 會把檔案截斷到這麼多行。
- **預設沒有時間戳記**。設定 `HISTTIMEFORMAT='%F %T '` 就能在 `history` 輸出
  得到 `2026-05-08 14:30:00 git status` 這種格式。檔案中會以 `#<unix-ts>`
  行的形式穿插在指令之間。

### 環境變數（本 repo 在 [`dot_config/bash/02_history.bash`](../../dot_config/bash/02_history.bash) 的預設值）

| 變數 | 本 repo | Bash 預設 | 效果 |
|---|---|---|---|
| `HISTSIZE` | `10000` | `500` | 記憶體中的最大筆數 |
| `HISTFILESIZE` | `20000` | `500` | 磁碟上的最大筆數（檔案在結束時被截斷） |
| `HISTCONTROL` | `ignoreboth` | unset | `ignoredups`+`ignorespace`：去除連續重複、捨棄 ` ` 開頭的 |
| `HISTIGNORE` | unset | unset | 以冒號分隔的 glob pattern 清單，會被略過（例如 `'ls:cd:exit:history'`） |
| `HISTTIMEFORMAT` | unset | unset | `history` 輸出的 strftime 格式 |
| `HISTFILE` | unset (→ `~/.bash_history`) | `~/.bash_history` | 檔案路徑 |

### `shopt`（本 repo）

| 選項 | 效果 |
|---|---|
| `histappend` | 在結束時附加到 `$HISTFILE` 而非覆寫（對於多 session 的主機是必要的） |
| `cmdhist` | 把多行指令存成一筆歷史 |
| `lithist` | （未設定）——會把多行指令以嵌入的換行字元儲存，而非分號 |
| `histverify` | （未設定）——會要求對 `!!` / `!N` 展開按兩次 Enter 才執行 |

### 為什麼跨 session 的 bash 歷史感覺會掉資料

預設的 bash 只在 **shell 結束時**寫入磁碟。如果你有三個 tmux pane，乾淨地
結束其中一個，第二個 pane 卻 crash，第二個的歷史就掉了。兩種修法（本 repo
兩者皆未採用——見下方 ble.sh 章節）：

```bash
# 每次提示後 flush
PROMPT_COMMAND='history -a'

# 每次提示雙向同步（多 pane 的「共享」感受，類似 zsh 的 share_history）
PROMPT_COMMAND='history -a; history -c; history -r'
```

完全同步的版本相當干擾（向上鍵會變成跨 pane 的全域時間軸，而不是你本地的）。
本 repo 改讓 ble.sh 來掌管同步行為。

## Zsh 歷史紀錄

### 儲存位置

- **檔案**：`$HISTFILE`，預設為 `~/.zsh_history`。首次寫入時權限為 `0600`。
- **格式**：在 `setopt extended_history`（OMZ 預設）下，每筆為
  `: <unix-ts>:<elapsed>;<command>`。前面那個 `: ` 是刻意的——它是 POSIX 的
  no-op 指令，讓檔案可以安全地被重新 source。
- **記憶體 ring**：`$HISTSIZE` 筆。
- **磁碟檔案上限**：`$SAVEHIST` 筆。在 `setopt hist_expire_dups_first`
  （OMZ 預設）下，達到上限時會先淘汰重複項。
- **跨 session 共享**：`setopt share_history`（OMZ 預設）讓每個指令立即
  附加到 `$HISTFILE`，並在所有其他存活的 zsh session 下次提示時被重新
  讀入。這就是為什麼在 pane B 的向上鍵能看到你剛在 pane A 輸入的指令。

### 本 repo 設定 ZERO 個自訂 zsh 歷史選項

出乎意料但屬實：`dot_zshrc.tmpl` 與 `dot_config/zsh/**/*.zsh` 不包含任何
`HISTSIZE` / `SAVEHIST` / `HISTFILE` / `setopt hist_*` 行。一切都來自
oh-my-zsh 的 [`lib/history.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/history.zsh)，
它會在 `source $ZSH/oh-my-zsh.sh` 時自動載入。

OMZ 的預設值（逐字摘錄，截至 2026 年）：

```zsh
[ -z "$HISTFILE" ] && HISTFILE="$HOME/.zsh_history"
[ "$HISTSIZE" -lt 50000 ] && HISTSIZE=50000
[ "$SAVEHIST" -lt 10000 ] && SAVEHIST=10000

setopt extended_history       # record timestamp of command in HISTFILE
setopt hist_expire_dups_first # delete duplicates first when HISTFILE size exceeds HISTSIZE
setopt hist_ignore_dups       # ignore duplicated commands history list
setopt hist_ignore_space      # ignore commands that start with space
setopt hist_verify            # show command with history expansion to user before running it
setopt share_history          # share command history data
```

注意 `[ … -lt … ]` 守衛：如果你在 `dot_config/shell/00_exports.sh.tmpl`
中 `export HISTSIZE=200000`（目前在第 149 行被註解掉），OMZ **不會把它
縮小**。只增不減。

### 覆寫 OMZ 預設值

在 `source $ZSH/oh-my-zsh.sh`（`dot_zshrc.tmpl` 第 62 行）**之前**設定變數。
共享的 `dot_config/shell/00_exports.sh.tmpl` 在第 21 行被 source，遠早於
OMZ——其中已有三個註解掉的範例：

```bash
# export HISTSIZE=10000
# export SAVEHIST=10000
# export HISTFILE="$XDG_DATA_HOME/zsh/history"
```

把 `HISTFILE` 設成 XDG 路徑時，你必須自己建立父目錄；zsh 拒絕建立缺少的中間
目錄，且會在路徑不可寫時靜默退回到只在記憶體中保留歷史。**沒有任何錯誤訊息**
——你只會發現向上鍵跨 session 後再也記不得任何東西。請在 export 旁邊加上
`mkdir -p "${HISTFILE%/*}"` 這一行。

### `omz_history` wrapper

OMZ 把 `history` 別名為一個 wrapper，支援 `-c`（清空，附帶確認提示）以及
由 `$HIST_STAMPS` 驅動的時間戳格式 flag。純 `fc -l` 仍然有效，且會繞過
這個 wrapper。

## ble.sh 與 bash-preexec 的互動

在 bash 上本 repo 會載入 `ble.sh`（見 [bash.md](bash.md) → init order）。ble.sh
在 attach 時**接管了歷史同步**：

- `ble-attach` 在 attach 時把 `$HISTFILE` 讀進 ble.sh 自己的 ring。
- 每個被接受的指令都會立即附加到 `$HISTFILE`（不必等 shell 結束，也不需要
  `PROMPT_COMMAND` flush 的小技巧）。
- ble.sh **掌管向上鍵的 keymap** 用於行內歷史導航。這就是為什麼在 bash 上
  atuin 必須以 `--disable-up-arrow` 初始化；見
  [AGENTS.md](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)
  → 「Keyboard shortcuts (cross-tool conflict check)」中的 `15_atuin.sh`
  invariant。
- `bash-preexec`（ble.sh 原生提供）讓 atuin 的 `__atuin_history` widget
  能夠捕捉指令以寫入它的 SQLite store。

實務後果：在 bash 搭配 ble.sh 上，歷史的即時感*幾乎*跟 zsh 的 `share_history`
一樣，但預設並非雙向——pane B 只會在下次 ble.sh 重新載入歷史後（例如觸發
`Ctrl+R` 或 `history -n` 之後）才看到 pane A 的指令。

## 伺服器上的多使用者稽核 (multi-user audit)

> **範圍說明**：本節涵蓋的是*實務系統管理員層級*——root 使用者透過讀取
> shell 歷史檔案與標準系統日誌可以看到什麼。如果要做合規等級的稽核
> （每一個被 exec 的 binary、每一個 syscall、竄改偵測），答案是 `auditd`
> ——本節結尾有一個簡短的指引。

### root 可以直接看到什麼

```bash
# 機器上所有 shell 歷史檔案
sudo ls -la /home/*/.{bash,zsh}_history /root/.{bash,zsh}_history 2>/dev/null

# 讀取其中一個
sudo cat /home/alice/.zsh_history

# 解碼時間戳（zsh extended_history 格式）
sudo awk -F';' '/^: / { ts=substr($1,3,10); cmd=substr($0, index($0,";")+1); print strftime("%F %T", ts), cmd }' /home/alice/.zsh_history
```

### 為什麼這樣不完整

讀檔案是會**漏資料的**：

| 漏失來源 | 機制 |
|---|---|
| 空白字元前綴規避 | bash 設定 `HISTCONTROL=ignorespace`（本 repo 預設）與 zsh 設定 `setopt hist_ignore_space`（OMZ 預設）會丟棄任何以空白開頭的行。`<space>curl https://example.com -H "Authorization: Bearer $TOKEN"` 永遠不會進到檔案。 |
| 手動刪除 | `history -d 42`（bash）或 `fc -p; fc -P` 之類的把戲（zsh）——互動式地把某筆從記憶體 ring 移除。然後使用者可以 `history -w` 把檔案覆寫掉。 |
| 截斷檔案 | `> ~/.bash_history` 或 `: > ~/.zsh_history` 然後結束。或是在可疑指令之前 `unset HISTFILE`，那個 session 就完全不會寫入。 |
| 換 shell | 如果使用者執行 `dash` / `fish` / `nu` / `xonsh` 而不是 bash/zsh，這兩個檔案都不會被動到。 |
| atuin 介入 | `atuin search` 是平行的另一份儲存。使用者可能 `atuin search --delete` 而完全沒動到 `~/.zsh_history`（反之亦然）。見下方 [atuin 如何改變整個局面](#atuin-如何改變整個局面)。 |
| 緩衝寫入 | 沒有 `histappend` + flush 的 bash 只會在乾淨結束時寫入。如果 shell 被 `kill -9`，記憶體中的歷史就消失了，檔案沒變動。 |

### Sudo 日誌（真正可靠的那一層）

任何透過 `sudo` 執行的東西都會被記錄，無論使用者的 shell 歷史設定為何：

```bash
# Debian/Ubuntu — auth.log
sudo grep sudo /var/log/auth.log

# RHEL/CentOS/Rocky — secure log
sudo grep sudo /var/log/secure

# 基於 systemd 的（任何現代發行版）— journal
sudo journalctl -t sudo --since "1 hour ago"
sudo journalctl _COMM=sudo --since today

# 依使用者過濾
sudo journalctl _COMM=sudo --grep 'USER=alice'
```

一行 sudo 紀錄看起來像：

```
May 08 14:30:00 host sudo: alice : TTY=pts/3 ; PWD=/home/alice ; USER=root ; COMMAND=/bin/cat /etc/shadow
```

如果要做 session **重播**（完整按鍵錄製，包含 stdout），把
`Defaults log_input,log_output` 加到 `/etc/sudoers.d/` 來啟用 `sudoreplay`。
然後：

```bash
sudo sudoreplay -l                  # 列出已錄製的 session
sudo sudoreplay <session-id>         # 即時重播
```

注意：這只會錄製 sudo 過的指令，不包含使用者單純的 shell。

### 帳號層級：誰登入、何時登入、執行了什麼

```bash
# 登入/登出歷史（來自 /var/log/wtmp）
last
last alice
last -F                              # 完整時間戳
last -i                              # IP 而非 hostname

# 失敗的登入（來自 /var/log/btmp）
sudo lastb

# 目前已登入的
who
w                                    # 加上他們現在正在執行什麼
```

要做每個 process 的 accounting（每個使用者執行的每一個 exec）請安裝 `acct`
（Debian/Ubuntu）或 `psacct`（RHEL）：

```bash
sudo apt install acct                # 或：sudo dnf install psacct
sudo systemctl enable --now acct     # 或：psacct

# 然後：
sudo lastcomm alice                  # alice 執行過的每個指令
sudo lastcomm --user alice --strict-match
sudo sa                              # 依指令彙整
sudo ac alice                        # 連線時間總計
```

`lastcomm` 只記錄 **process 名稱**（16 字元，沒有引數，沒有 cwd），但因為
kernel 直接寫入 `/var/log/account/pacct`，從使用者端是抗竄改的。對於
「alice 這週是否執行過 `nmap`？」很有用——對於「alice 那次的 `nmap` 實際
掃了什麼？」沒用。

### 當你需要真正的答案：auditd

如果要 exec syscall 引數、檔案存取、網路連線，以及防竄改的 log，答案是
Linux 的 audit framework：

```bash
sudo apt install auditd
sudo auditctl -a always,exit -F arch=b64 -S execve -k user_cmd
sudo ausearch -k user_cmd -ts today
sudo aureport --executable --summary
```

超出本文件範圍——它是個資安工具的兔子洞。僅作為指引。請見 `man auditctl`
與 [Red Hat auditd 指南](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening)。

## 清除自己的歷史紀錄

> **威脅模型 (threat model)**：本節是關於把不小心貼到 shell 的機密
> 從你*自己*的 shell 歷史檔案中藏起來（防的是明天的你 `cat ~/.bash_history`，
> 或某個拿到 root 的善意隊友）。它**不是**用來防禦擁有 sudo 或 kernel 存取
> 的對手——上面的 [Sudo 日誌](#sudo-日誌真正可靠的那一層) 與
> [auditd](#當你需要真正的答案auditd) 已經說明了原因。

### 一次性：完全不要記錄這個指令

```bash
 export TOKEN=ghp_xxxxx                   # ← 開頭有空白，會被 ignorespace 丟掉
```

bash（`HISTCONTROL=ignoreboth`）與 zsh（`setopt hist_ignore_space`，OMZ
預設）都會遵守這個規則。在依賴它之前先驗證一下：

```bash
echo "$HISTCONTROL"                       # bash：應該包含 ignorespace 或 ignoreboth
setopt | grep histignorespace             # zsh：應為 'on'（沒有 'no' 前綴）
```

### 從目前 session 刪除特定一筆

```bash
# bash
history                                   # 找到行號，例如 142
history -d 142
history -w                                # 把記憶體 ring flush 到 $HISTFILE

# zsh
fc -l -100                                # 找到 offset
# 然後要嘛在編輯 $HISTFILE 後重啟 shell，要嘛：
LC_ALL=C sed -i.bak '/secret-pattern/d' "$HISTFILE"
fc -p "$HISTFILE"                         # 重新讀入目前 session
```

zsh 沒有內建的 `history -d N` 等價指令——`fc` 只能編輯記憶體中的內容，
而在 `share_history` 下，等你發現時那筆已經在磁碟上了。請編輯檔案，再
`fc -p`。

### 整個歷史紀錄全清（目前使用者）

```bash
# bash
history -c                                # 清空記憶體 ring
history -w                                # 把空 ring 寫入檔案
# 或直接截斷：
: > ~/.bash_history

# zsh — OMZ 提供帶確認提示的 wrapper
history -c                                # 詢問 "Are you sure? [y/N]"
# 或原始做法：
: > "$HISTFILE"
fc -p "$HISTFILE"                         # 重新 attach 現在已是空的檔案
```

### 別忘了 atuin

如果有裝 atuin（本 repo 有，見 [tools/atuin.md](../tools/atuin.md)），
上述步驟只清掉 bash/zsh 原生檔案。Atuin 的 SQLite 儲存還另外抓了同樣的
指令：

```bash
# 搜尋並選擇性刪除
atuin search 'secret-pattern' --delete

# 或全部清掉（不可逆）
atuin search --before '1 day ago' --delete   # 在某個時間點之前
# 沒有 `atuin wipe` 指令——要徹底清掉：
rm -rf ~/.local/share/atuin/history.db
atuin init zsh                                # 重新初始化空的 store
```

如果你有設定 `atuin login`（同步到伺服器），`atuin search --delete` 會在
下次 `atuin sync` 時把刪除動作傳播到伺服器。檔案層級的清除**不會**——
伺服器上那一列還在。如果你需要在伺服器端清除，使用 `atuin account delete`，
或者跑你自己 self-hosted 的 `atuin server`，這樣資料庫由你掌控。

### 仍然會洩漏的東西

做完上面所有事之後，一個有 sudo 的鍥而不捨的調查者仍可以還原：

- 你的 `sudo` 呼叫（auth.log / journalctl / sudoreplay）。
- 任何活得夠久而能出現在 `ps`/`top` 快照中的 process。
- 啟用了 `acct`/`psacct` 的話，每個 process 的紀錄。
- 啟用了 auditd 的話，execve 的紀錄。
- 如果你沒有 `clear` 與 `reset`，終端機的 scrollback。
- 如果有裝 `tmux-resurrect`，`~/.tmux/resurrect/` 中的 tmux scrollback。
- 如果你用編輯器開過含機密的檔案，編輯器的 swap 檔（`.swp`、`~`、`.~lock.*`）。
- 如果 `sh -x` / `set -x` 啟用且有導向，你的 shell **operations log**。

先做威脅模型，再做 clear-history 表演秀。

## atuin 如何改變整個局面

[atuin](https://atuin.sh/)（[upstream](https://github.com/atuinsh/atuin)）
是一個平行的、以 SQLite 為後端的歷史儲存，並提供選用的端對端加密同步。
它**不會**取代 `~/.{bash,zsh}_history`——而是與其並存。兩個檔案都會繼續成長。

| 面向 | 原生 bash/zsh 歷史 | atuin |
|---|---|---|
| 儲存 | 純文字（`~/.{bash,zsh}_history`） | SQLite（`~/.local/share/atuin/history.db`） |
| 每筆指令的中繼資料 | Bash：無。Zsh `extended_history`：時間戳 + 持續時間 | 時間戳、持續時間、exit code、cwd、hostname、session id |
| 搜尋 | `Ctrl+R` 線性 `grep` 風格（或本 repo 的 fzf-tab） | 模糊搜尋 + 依 cwd / session / host / exit-status / 時間範圍過濾 |
| 跨主機共享 | 手動（`scp ~/.zsh_history`） | `atuin login` + `atuin sync`（E2E 加密，伺服器無法讀取） |
| 預設筆數上限 | bash `$HISTFILESIZE=20000`、zsh `$SAVEHIST=10000` | **無上限。** SQLite 永遠成長（約 100 bytes/筆，所以 ~1MB / 10k 筆）。 |
| 保留期相關環境變數 | `HISTSIZE` / `HISTFILESIZE` / `SAVEHIST` / `HISTIGNORE` / `HISTCONTROL` | `~/.config/atuin/config.toml`：`history_filter`（regex 陣列）是最接近的等價物——在*捕捉時*就丟棄符合的指令 |
| 清除 | 編輯/截斷檔案 | `atuin search ... --delete`，會透過同步傳播 |
| At-rest 加密 | 無 | 預設無（SQLite db 在磁碟上是明文；只有*同步傳輸線*以使用者金鑰做 E2E 加密） |

### atuin 的「最大筆數」故事

沒這回事。最接近的旋鈕：

- `history_filter = ['^secret', '^export TOKEN']` — regex 陣列；符合的會在
  捕捉時被靜默丟棄（類似強化版的 `HISTIGNORE`）。
- `cwd_filter = ['^/tmp']` — 在符合的目錄下執行的指令會被丟棄。
- `inline_height = 0` 與 pager 設定 — 只影響 UI，不影響儲存。
- `sync.records_size_limit` — 伺服器端每筆紀錄的上限（預設 1 MiB），
  並非筆數上限。

如果你需要真正的上限，跑一個 cron / systemd timer：

```bash
# 只保留最近 90 天
sqlite3 ~/.local/share/atuin/history.db \
  "DELETE FROM history WHERE timestamp < strftime('%s', 'now', '-90 days') * 1000000000;"
atuin sync                                # 把刪除動作傳播出去
```

這在 atuin 端是刻意設計——它的設計假設是「你的歷史很小，而且你想要永遠
保留所有內容並可模糊搜尋」。跟 bash 那種「會遺忘的環狀緩衝區」是不同的
哲學。

關於安裝設定、快捷鍵，以及本 repo 中 bash↔zsh 的不對稱，請見
**[tools/atuin.md](../tools/atuin.md)**。

## 相關文件

- [tools/atuin.md](../tools/atuin.md) — atuin 的安裝設定、快捷鍵、同步、
  本 repo 中 bash↔zsh 的不對稱。
- [shells/bash.md](bash.md) — bash init order、ble.sh 的 attach 點。
- [shells/keybindings.md](keybindings.md) — 各 shell 的 `Ctrl+R` / `Alt+R`
  / atuin 綁定。
- [shells/aliases.md](aliases.md) — 被 source 的檔案註冊表。
- [`dot_config/bash/02_history.bash`](../../dot_config/bash/02_history.bash) —
  本 repo 中唯一設定 shell 歷史環境變數的檔案。
- 上游：
  [bash `HISTORY` man page 章節](https://www.gnu.org/software/bash/manual/html_node/Bash-History-Facilities.html)、
  [zsh history options](https://zsh.sourceforge.io/Doc/Release/Options.html#History)、
  [oh-my-zsh `lib/history.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/history.zsh)、
  [atuin docs](https://docs.atuin.sh/)、[atuin GitHub](https://github.com/atuinsh/atuin)。
