# Setup SSH Key on Remote Machine

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

將本機 SSH 金鑰 (key) 複製到遠端主機 (remote machine)（例如 Raspberry Pi），同時用於 SSH 登入與 GitHub 存取。

## 先決條件 (Prerequisites)

- 可以 SSH 連線到遠端主機（一開始使用密碼驗證）
- 已將公鑰 (public key) 加到你的 GitHub 帳號：<https://github.com/settings/keys>

## 0. 建立 SSH 金鑰

### 選擇演算法 (algorithm)

| 演算法 | 命令 | 備註 |
|-----------|---------|-------|
| **Ed25519** | `ssh-keygen -t ed25519` | 推薦。快速、安全、金鑰短小。任何環境都能用（OpenSSH >= 6.5）。 |
| **Ed25519-SK** | `ssh-keygen -t ed25519-sk` | 綁定硬體（FIDO2 / YubiKey）。簽署時需要實體觸碰。 |
| **ECDSA-SK** | `ssh-keygen -t ecdsa-sk` | 給不支援 Ed25519-SK 的舊款 YubiKey 的 FIDO2 備援方案。 |
| **RSA (4096)** | `ssh-keygen -t rsa -b 4096` | 僅供舊系統相容。連線到非常老舊的系統時才使用。 |
| **ECDSA** | `ssh-keygen -t ecdsa -b 521` | 較少見；相較 Ed25519 沒有優勢。 |

**TL;DR**：除非你需要硬體金鑰（`ed25519-sk`）或舊系統相容（`rsa`），不然就用 `ed25519`。

### 產生金鑰

```bash
# 基本（會互動式詢問路徑與 passphrase）
ssh-keygen -t ed25519 -C "your_email@example.com"

# 明確指定檔案路徑與註解
ssh-keygen -t ed25519 -f ~/.ssh/<key> -C "description or email"

# 搭配 YubiKey（需要先把 key 插上）
ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sk -C "yubikey"
```

### 要不要設 passphrase？

| 情境 | 設 passphrase？ | 為什麼 |
|----------|-------------|-----|
| 個人電腦，已啟用全磁碟加密 | 可選 | 磁碟加密已經保護了檔案 |
| 共用 / 多使用者主機 | 設 | 防止其他使用者或程式 (process) 使用你的金鑰 |
| CI/CD、自動化、無人值守 server | 不設 | 沒有人類可以輸入；改用檔案權限 + 密碼管理工具 (secrets manager) |
| 高安全 / 合規場景 | 設 | 縱深防禦；搭配 SSH agent 只需輸入一次 |

> **提示**：日後可以在不重新產生金鑰的情況下變更或移除 passphrase：
>
> ```bash
> ssh-keygen -p -f ~/.ssh/<key>
> ```

### 建立金鑰之後的管理方式

#### 純檔案（最簡單）

金鑰以檔案形式放在 `~/.ssh/`。你在 `~/.ssh/config` 中明確指定它們：

```
Host github.com
    IdentityFile ~/.ssh/<key>
```

優點：簡單、可攜。缺點：金鑰檔案存在磁碟上、必須複製到每台機器。

#### SSH agent

把金鑰載入 agent，每個會話 (session) 只需輸入一次 passphrase：

```bash
# 啟動 agent（此 repo 會自動處理，見 docs/tools/ssh-agent.md）
eval "$(ssh-agent -s)"

# 加入金鑰（若有設 passphrase 會提示輸入）
ssh-add ~/.ssh/<key>

# macOS：把 passphrase 存進 Keychain（重開機後仍有效）
ssh-add --apple-use-keychain ~/.ssh/<key>
```

#### Bitwarden SSH Agent

把金鑰存放在 Bitwarden 保險庫 (vault) 內；桌面應用程式 (desktop app) 擔任 SSH agent。初次匯入後，磁碟上不再有金鑰檔案。

完整設定見 [Bitwarden SSH Agent tutorial](./bitwarden_ssh_agent.md)。

#### 1Password / 其他密碼管理工具

概念與 Bitwarden 類似 -- 應用程式提供 SSH agent socket。詳見你使用之密碼管理工具的官方文件。

#### YubiKey (FIDO2)

私鑰**永遠不會離開硬體**。`-sk` 系列金鑰類型（`ed25519-sk`、`ecdsa-sk`）會在 `~/.ssh/` 產生 key handle，但實際的簽署運算在 YubiKey 上完成。每次 SSH 操作都需要把 YubiKey 插上。

#### 比較

| 方法 | 金鑰是否在磁碟？ | 是否可跨機器攜帶？ | 是否每個 session 需輸入 passphrase？ |
|--------|-------------|--------------------------|-------------------------------|
| 純檔案 | 是 | 手動複製 | 每次都要（或不設 passphrase） |
| SSH agent | 是（已載入記憶體） | 複製金鑰，agent 自動載入 | 每個 session 一次 |
| Bitwarden / 1Password | 否（匯入後就無） | 透過 vault 同步 | 解鎖 vault 一次 |
| YubiKey | 僅有 handle | 攜帶實體金鑰 | 每次操作觸碰一次 |

### `IdentitiesOnly yes`

預設情況下，SSH client 會把 agent 內的**所有金鑰**逐一提供給伺服器 (server)，全部試完才會嘗試 `IdentityFile`。下列情境會出問題：

1. **agent 內金鑰太多** -- 多數伺服器只允許 5-6 次驗證嘗試。如果你的 agent 持有 8 把以上的金鑰，伺服器會在試到正確金鑰之前就以 `Too many authentication failures` 拒絕你。
2. **錯誤金鑰用在錯誤主機** -- 沒有限制時，SSH 可能用非預期的金鑰登入伺服器（例如把私人金鑰用在公司伺服器）。
3. **安全 / 稽核** -- 你想保證每台主機使用哪一把金鑰是固定的。

在 SSH 設定中加入 `IdentitiesOnly yes`，可讓 SSH **只**使用 `IdentityFile` 指定的金鑰，忽略 agent 中的其他金鑰：

```
# 個別主機
Host github.com
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes

# 或全域套用（金鑰多時建議）
Host *
    IdentitiesOnly yes
```

> **注意**：使用 `IdentitiesOnly yes` 時，每個 host 條目**都必須**設 `IdentityFile` -- SSH 不會回退去使用 agent 中的金鑰。如果你使用密碼管理工具的 agent（Bitwarden/1Password），通常**不**會想全域套用，因為 agent 才是金鑰的唯一來源。

| 情境 | `IdentitiesOnly` | 為什麼 |
|----------|-------------------|-----|
| 金鑰少、只有單一 agent | 否（預設） | agent 全部試一遍也沒問題 |
| agent 中金鑰很多（5+） | **是** | 防止「too many failures」 |
| 多個 GitHub/GitLab 帳號 | **是** | 強制每台主機使用正確金鑰 |
| 僅用 Bitwarden/1Password agent | 否 | agent 就是身份來源 |
| 檔案金鑰與 agent 金鑰混用 | 各主機分別設 **是** | 明確控制 |

## 1. 啟用 SSH 登入到遠端主機

### 一般金鑰檔案

```bash
ssh-copy-id -i ~/.ssh/<key>.pub user@remote
```

這會把公鑰附加到遠端的 `~/.ssh/authorized_keys`。

### YubiKey / 硬體安全金鑰

如果你的金鑰存放在 YubiKey 上（FIDO2 或 PIV），磁碟上沒有私鑰檔案 -- 只剩 `.pub` 檔或 agent 知道它。

```bash
# 如果你有 .pub 檔（ed25519-sk / ecdsa-sk）
ssh-copy-id -i ~/.ssh/id_ed25519_sk.pub user@remote

# 如果金鑰只存在於 agent（YubiKey PIV、gpg-agent 等）
# ssh-copy-id 會自動使用 agent 中的金鑰
ssh-copy-id user@remote
```

### SSH agent（Bitwarden、1Password、gpg-agent 等）

當你的金鑰由 SSH agent 管理，且磁碟上沒有 `.pub` 檔案時：

```bash
# 列出 agent 目前持有的金鑰
ssh-add -L

# ssh-copy-id 會自動取用 agent 的金鑰
ssh-copy-id user@remote

# 或從 agent 將特定金鑰透過管線送出
ssh-add -L | grep "<key comment or type>" | ssh user@remote 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
```

> **注意**：請確認 `SSH_AUTH_SOCK` 指向正確的 agent。
> 此 repo 如何管理 `SSH_AUTH_SOCK` 詳見 [SSH Agent Fallback](../tools/ssh-agent.md)。

接著在本機 `~/.ssh/config` 加入：

```
Host rpi
    HostName <IP or hostname>
    User <user>
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes          # 可選：只使用此金鑰，忽略 agent
```

驗證：`ssh rpi` 應該能不需密碼直接登入。

## 2. 將金鑰對複製到遠端

```bash
scp ~/.ssh/<key> ~/.ssh/<key>.pub rpi:~/.ssh/
ssh rpi 'chmod 600 ~/.ssh/<key> && chmod 644 ~/.ssh/<key>.pub'
```

## 3. 在遠端設定 GitHub SSH

```bash
ssh rpi 'cat >> ~/.ssh/config << EOF

Host github.com
    IdentityFile ~/.ssh/<key>
EOF'
ssh rpi 'chmod 600 ~/.ssh/config'
```

## 4. 將 Git remote 從 HTTPS 切換為 SSH

```bash
ssh rpi 'cd /path/to/repo && git remote set-url origin git@github.com:<user>/<repo>.git'
```

通用的轉換規則：`https://github.com/<user>/<repo>.git` → `git@github.com:<user>/<repo>.git`

## 5. 驗證

```bash
# 測試 GitHub SSH 驗證
ssh rpi 'ssh -T git@github.com'
# 預期: "Hi <user>! You've successfully authenticated..."

# 測試 git push
ssh rpi 'cd /path/to/repo && git push'
```

## 自動化：`ssh-setup-remote`

此 repo 提供一個 shell function，會以互動式流程帶你走過上述所有步驟：

```bash
ssh-setup-remote user@hostname
```

它會提示你：

1. **選擇或建立** SSH 金鑰（演算法、名稱、passphrase）
2. **ssh-copy-id** 公鑰以啟用免密碼登入
3. **複製金鑰對**到遠端（可選，用於 GitHub 存取）
4. **在遠端加入 GitHub SSH 設定**（可選）
5. **把金鑰接進本機 `~/.ssh/config`** —— 精靈會分辨兩種情況：
   - 若該別名**已經設定過**（會遞迴沿著 `Include ~/.ssh/config.d/*` 找到實際所在的檔案），就
     **直接在既有的 `Host` 區塊內就地加入 `IdentityFile`**，而非附加重複區塊。若區塊已有
     `IdentityFile`，會詢問要*取代* / *再加一條* / *略過*；用同一把金鑰重跑則為無動作。
   - 若是**新主機**（例如 `user@ip`），則附加一個全新的別名區塊（寫到 `~/.ssh/config` 或
     `~/.ssh/config.d/` drop-in），並可選擇加上 `IdentitiesOnly yes`。當寫入 drop-in 但你的
     `~/.ssh/config` 沒有對應的 `Include` 行時，會主動詢問是否補上，讓該設定真正生效。

   > 就地編輯需要 `python3`；若環境中沒有 `python3`，精靈會退回到僅附加（append-only）的行為。

來源：`~/.config/shell/96_ssh_setup.sh`

## 疑難排解 (Troubleshooting)

### Remote Host Identification Has Changed

連線時若看到 `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`，代表伺服器的 host key 已和 `~/.ssh/known_hosts` 內存的紀錄不符。常見於重新安裝作業系統，或同一個 IP 重新佈建 (reprovision) server 之後。

移除舊金鑰後重新連線：

```bash
ssh-keygen -R <host>
ssh user@<host>   # 出現提示時接受新的 key
```

錯誤訊息會告訴你是哪一行（例如 `Offending ECDSA key in ~/.ssh/known_hosts:89`），但 `ssh-keygen -R` 會根據 hostname/IP 自動處理移除。
