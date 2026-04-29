# SSH Agent

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

自動化的 SSH agent 管理：以 Bitwarden 為優先，並 fallback 到 `ssh-agent`。

**設定檔**：`~/.config/zsh/tools/94_ssh_agent.zsh`

---

## 觀念

### 什麼是 SSH 金鑰對 (key pair)？

SSH 採用非對稱加密 (asymmetric cryptography) —— 一把**私鑰 (private key)**（必須保密）與一把**公鑰 (public key)**（可自由分享）。

```
~/.ssh/id_ed25519      ← 私鑰（絕對不要外流）
~/.ssh/id_ed25519.pub  ← 公鑰（貼到伺服器／GitHub）
```

當你連線到伺服器 (server) 時，SSH 會用私鑰完成一次密碼學挑戰 (challenge) 來證明身分；伺服器則用 `~/.ssh/authorized_keys` 中的公鑰來驗證。

**金鑰類型**（新建議使用 ed25519）：

| 類型 | 強度 | 備註 |
|------|----------|-------|
| `ed25519` | 現代且建議 | 金鑰短、速度快、安全 |
| `rsa`（4096-bit） | 相容性廣 | 較舊；若已在使用仍可接受 |
| `ecdsa` | 良好 | 較少見 |

產生新金鑰：
```bash
ssh-keygen -t ed25519 -C "your@email.com"
# 會儲存至 ~/.ssh/id_ed25519 與 ~/.ssh/id_ed25519.pub
```

### 什麼是 passphrase？

passphrase 會把磁碟上的私鑰檔案加密。沒有它的話，任何拿到檔案的人都能直接使用。

**取捨：**
- 沒有 passphrase：方便，但機器一旦被入侵就有風險
- 有 passphrase：安全，但每次使用金鑰都要輸入 —— 除非搭配 **SSH agent**

### 什麼是 SSH agent？

SSH agent 是一個背景行程 (background process)，在記憶體中持有你**已解密的私鑰**。當 SSH 需要簽署挑戰時，會請 agent 代簽 —— 因此你只需在**每次登入工作階段 (session)** 輸入一次 passphrase，而不是每次連線都要輸入。

```
┌───────────┐  challenge  ┌───────────────┐  sign  ┌─────────────┐
│  ssh/git  │ ──────────▶ │   ssh-agent   │ ──────▶ │  decrypted  │
│  client   │ ◀────────── │  (in memory)  │         │   key copy  │
└───────────┘  signature  └───────────────┘         └─────────────┘
        ↑
        └── "Connected!"
```

通訊是透過 `SSH_AUTH_SOCK` 指向的 **Unix socket**：

```bash
echo $SSH_AUTH_SOCK    # 例如 /run/user/1000/ssh-agent/agent.sock
ssh-add -l             # 列出 agent 目前持有的金鑰
ssh-add ~/.ssh/id_rsa  # 手動加入金鑰（會問一次 passphrase）
```

### 自動載入金鑰的運作方式（以及 passphrase 提示）

當 fallback 的 `ssh-agent` 啟動且尚未持有任何金鑰時，`94_ssh_agent.zsh` 中的 `_maybe_add_keys` 會嘗試自動加入常見的金鑰檔：

```zsh
# key_names 清單：id_ed25519, id_rsa, id_ecdsa, jingle
SSH_ASKPASS_REQUIRE=never ssh-add -q "$kf" 2>/dev/null
```

**`SSH_ASKPASS_REQUIRE=never`** 是告訴 ssh-add：「完全不要詢問 passphrase —— 如果需要，就靜默失敗。」這意味著：

- **沒有** passphrase 的金鑰 → 自動靜默載入到 agent
- **有** passphrase 的金鑰 → 跳過（登入時不會跳出提示）

> **為什麼不用 `</dev/null`？** `ssh-add` 會繞過 stdin，直接開啟 `/dev/tty` 來讀取 passphrase，所以重新導向 stdin 沒有效果。`SSH_ASKPASS_REQUIRE` 才是正確機制（自 OpenSSH 8.4，2020 年起可用）。

**手動載入帶 passphrase 的金鑰**（每個 session 一次）：
```bash
ssh-add ~/.ssh/id_rsa
# Enter passphrase: ••••••
# 此 session 後續期間，金鑰都會留在 agent 中
```

---

## 運作方式

每個新的 interactive shell 都會跑下列 fallback 流程：

```
1. Bitwarden SSH agent socket？  ──是──▶  使用之 (export SSH_AUTH_SOCK)
         │ 否
         ▼
2. 既有的 SSH_AUTH_SOCK 可用？   ──是──▶  保留之（forwarded agent、systemd、gnome-keyring 等）
         │ 否
         ▼
3. 持久 ssh-agent                ──────▶  生成一次，跨 shell 重用
         │                                  自動從 ~/.ssh/ 載入沒有 passphrase 的金鑰
         ▼
   SSH_AUTH_SOCK 已設定並就緒
```

### 步驟 1：Bitwarden SSH Agent

逐一嘗試已知的 Bitwarden socket 路徑（完整對照表見 [bitwarden_ssh_agent.md](../tutorials/bitwarden_ssh_agent.md#2-configure-ssh_auth_sock)）。
每個候選 socket 都會以 `ssh-add -l` 加上 **2 秒逾時 (timeout)** 探測：

- Socket 不存在（`-S` 測試失敗）→ 立刻略過
- Socket 存在但 `ssh-add -l` **逾時**（agent 卡住）→ 略過
- Socket 回應 "agent refused operation"（Bitwarden 已鎖定／已停用）→ 略過
- Socket 回應金鑰列表或 "no identities" → **使用之**

這代表 Bitwarden 鎖定／當機時不會卡住 shell 啟動。

### 步驟 2：既有的 Agent

尊重環境中已設定的任何 `SSH_AUTH_SOCK`：
- SSH agent 轉發 (forwarding) （`ssh -A`）
- systemd `ssh-agent.service`
- GNOME Keyring
- 支援 SSH 的 GPG agent

如果目前的 socket 有效且有回應，就保留不變。

### 步驟 3：持久 ssh-agent

當 Bitwarden 與既有 agent 都不可用時，會以**固定 socket 路徑**生成一個標準的 `ssh-agent`：

```
$XDG_RUNTIME_DIR/ssh-agent/agent.sock   （Linux，常見：/run/user/1000/ssh-agent/）
$HOME/.cache/ssh-agent/agent.sock        （當 XDG_RUNTIME_DIR 未設定時的 fallback）
```

關鍵特性：
- **每位使用者一個 agent**：所有 shell 共用同一個 socket，不會出現孤兒 agent。
- **可跨 shell 重啟存活**：開新終端時會重用既有 agent。
- **自動載入金鑰**：第一次使用時（agent 內無 identity 時），會自動對常見金鑰名稱執行 `ssh-add`：`id_ed25519`、`id_rsa`、`id_ecdsa`、`jingle`。有 passphrase 的金鑰會被靜默跳過。

---

## SSH 設定檔基礎

`~/.ssh/config` 讓你能定義別名 (alias) 與每台主機的設定，避免每次都得輸入冗長的選項。

### 結構

```ssh-config
Host <alias>
    HostName <real hostname or IP>
    User <username>
    Port <port>          # 預設：22
    IdentityFile <path>  # 要使用的金鑰
```

### 常見模式

#### 簡單別名

```ssh-config
Host rpi
    HostName 100.64.157.9   # Tailscale IP 或域名
    User keithkslee
```

之後 `ssh rpi` 即可，不必再打 `ssh keithkslee@100.64.157.9`。

#### 指定要使用的金鑰

```ssh-config
Host github.com
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes   # 不要嘗試 agent 中其他金鑰
```

`IdentitiesOnly yes` 可避免 SSH 對伺服器丟出 agent 內所有金鑰。當伺服器拒絕過多次認證嘗試時很有用。

#### Agent 轉發

```ssh-config
Host rpi
    HostName 100.64.157.9
    User keithkslee
    ForwardAgent yes   # 你本機 agent 的金鑰可在遠端主機使用
```

啟用 `ForwardAgent yes` 後，登入遠端機器之後可以直接 `git pull`、`ssh` 至其他伺服器，使用本機的金鑰 —— 而**不需把私鑰複製到遠端機器**。

> **安全注意**：只將 agent 轉發給你信任的主機。任何在遠端機器擁有 root 的人，都能使用你轉發過去的 agent socket。

#### 跳板主機 (ProxyJump)

如果某台伺服器只能透過跳板／bastion 主機連線：

```ssh-config
Host bastion
    HostName bastion.example.com
    User admin

Host internal-server
    HostName 10.0.0.5
    User app
    ProxyJump bastion   # 自動透過 bastion 進行 SSH 連線
```

`ssh internal-server` 會自動透過 `bastion` 進行連線。

#### 常用選項對照

| 選項 | 作用 |
|--------|-------------|
| `HostName` | 真正的 hostname／IP（別名放在 `Host`） |
| `User` | 遠端使用者名稱 |
| `Port` | SSH port（預設 22） |
| `IdentityFile` | 私鑰路徑（`~/.ssh/id_ed25519`） |
| `IdentitiesOnly yes` | 只使用指定的金鑰，不使用 agent 內所有金鑰 |
| `ForwardAgent yes` | 將本機 SSH agent 轉發到遠端 |
| `ProxyJump <host>` | 透過跳板主機連線 |
| `ServerAliveInterval 60` | 每 60 秒送 keepalive（避免被 timeout） |
| `StrictHostKeyChecking no` | 略過主機金鑰驗證（僅限你能保證安全的內部主機） |

---

## 偵錯

```bash
# 目前是哪一個 agent？
echo $SSH_AUTH_SOCK

# Agent 是否有回應？
ssh-add -l

# 選擇了哪一條策略？
# 用 verbose 模式重新 source：
zsh -x -c 'source ~/.config/zsh/tools/94_ssh_agent.zsh' 2>&1 | grep SSH_AUTH_SOCK

# 強制走 fallback（略過 Bitwarden）以利測試：
unset SSH_AUTH_SOCK
source ~/.config/zsh/tools/94_ssh_agent.zsh
echo $SSH_AUTH_SOCK

# Verbose 模式的 SSH 連線（會顯示嘗試使用的金鑰）
ssh -v user@host
ssh -vvv user@host  # 更 verbose
```

## 疑難排解

| 症狀 | 原因 | 修法 |
|---|---|---|
| `ssh-add -l` → "Could not open connection" | 沒有 agent 在跑、腳本未執行 | 確認 `source ~/.config/zsh/tools/94_ssh_agent.zsh` 沒有錯誤地完成 |
| Bitwarden socket 存在但仍走 fallback | Bitwarden 已鎖定或 agent 已停用 | 解鎖 Bitwarden、在 **Settings** 中啟用 SSH agent |
| 多個 ssh-agent 行程 | 是這支腳本之前殘留的舊 agent | `pkill ssh-agent`，再開新 shell |
| 金鑰沒有被自動載入 | 金鑰檔名不在清單裡 | 將檔名加入 `94_ssh_agent.zsh` 中的 `key_names` 陣列 |
| Agent 在重開機後消失 | XDG_RUNTIME_DIR 是 tmpfs（預期） | 正常 —— agent 會在下次開啟 shell 時重新生成 |
| 登入時跳出 passphrase 提示 | `~/.ssh/` 中有帶 passphrase 的金鑰，且 OpenSSH < 8.4 | `SSH_ASKPASS_REQUIRE=never` 需要 OpenSSH 8.4+；請升級或從 `key_names` 移除該金鑰 |
| `Permission denied (publickey)` | 公鑰不在伺服器的 `authorized_keys` 中 | 執行 `ssh-copy-id user@host`，或將 `~/.ssh/id_*.pub` 內容附加到伺服器的 `~/.ssh/authorized_keys` |
| 即使有金鑰，SSH 仍要求密碼 | 金鑰錯誤或不在 agent 中 | 用 `ssh-add -l` 檢查；`ssh -v user@host` 追蹤 |

## 自訂

### 加入更多自動載入的金鑰檔

編輯 `94_ssh_agent.zsh` 中的 `key_names` 陣列：

```zsh
local -a key_names=(id_ed25519 id_rsa id_ecdsa jingle my_work_key)
```

### 完全停用自動載入

把 `_fallback_ssh_agent` 內呼叫 `_maybe_add_keys` 那一行註解掉。

### 改用 systemd ssh-agent 取代內建 fallback

如果你偏好讓 systemd 管理 agent：

```bash
# 建立服務
systemctl --user enable --now ssh-agent

# 在環境設定 SSH_AUTH_SOCK
echo 'export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"' >> ~/.zshrc.adhoc
```

fallback 腳本的步驟 2 會偵測到並略過步驟 3。

## 相關文件

- [Bitwarden SSH Agent 教學](../tutorials/bitwarden_ssh_agent.md) —— 將 Bitwarden 設為 agent 的完整設定指南
- `~/.config/zsh/tools/94_ssh_agent.zsh` —— SSH agent 自動偵測與 fallback
- `~/.config/zsh/tools/95_bitwarden.zsh` —— Bitwarden CLI 的 zsh 補全
