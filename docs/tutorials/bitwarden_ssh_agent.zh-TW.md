# Bitwarden SSH Agent

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

把 `Bitwarden` 桌面應用程式 (desktop app) 當作你的 SSH agent 使用，讓私鑰 (private key) 永遠不離開保險庫 (vault)。

- **官方文件**：<https://bitwarden.com/help/ssh-agent/>
- **需求**：Bitwarden desktop >= 2025.1.2，並在 **Settings > Enable SSH agent** 啟用 SSH agent

## 0. 安裝 Bitwarden Desktop

### 自動化（透過此 repo）

當 `chezmoi init` 期間啟用 `installBitwarden` 時，ansible bitwarden role 會自動安裝：

- **CLI** (`bw`)：所有 profile 皆透過 npm 安裝
- **Desktop app**：僅在 desktop profile 安裝（`ubuntu_desktop`、`macos`）
    - **macOS**：透過 Homebrew Cask（`brew install --cask bitwarden`）
    - **Ubuntu**：優先使用 Snap，`.deb` 下載作為備援

```bash
# 在 chezmoi init 期間啟用（如果還沒啟用）
chezmoi init --force  # 在 "Install Bitwarden CLI" 提示回答 "y"

# 或手動執行 bitwarden role 並一併安裝桌面版
cd ~/.ansible && ansible-playbook playbooks/linux.yml --tags bitwarden --extra-vars "bitwarden_install_desktop=true"
```

### 手動安裝

如果你偏好手動安裝，或正在使用 `ubuntu_server`：

- **macOS**：`brew install --cask bitwarden`
- **Ubuntu (snap)**：`sudo snap install bitwarden`
- **Ubuntu (.deb)**：從 [vault.bitwarden.com](https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=deb) 下載
- **Flatpak**：`flatpak install flathub com.bitwarden.desktop`

## 運作原理

```
┌──────────────┐     SSH_AUTH_SOCK      ┌───────────────────┐
│  ssh / git   │ ───────────────────▶   │  Bitwarden Agent  │
│  (any CLI)   │                        │  (desktop app)    │
└──────────────┘                        └───────────────────┘
                                              │
                                              ▼
                                        Vault (encrypted)
                                        ├─ SSH: ssh_key_1
                                        ├─ SSH: ssh_key_2
                                        └─ SSH: ssh_key_3
```

當 SSH client 需要金鑰 (key) 時，會與 `SSH_AUTH_SOCK` 指向的 agent 溝通。
Bitwarden 會建立一個 Unix socket 檔案；把 `SSH_AUTH_SOCK` 指向該 socket 就能讓 Bitwarden 成為 agent。
桌面應用程式會在每次使用金鑰時提示你授權（可在 Settings 內設定）。

## 1. 將金鑰匯入 Bitwarden

### 透過桌面應用程式

1. 開啟 Bitwarden desktop，點選 **New > SSH key**。
2. 使用 **Import key from clipboard** 貼上你的私鑰（OpenSSH 或 PKCS#8 格式）。
3. 公鑰 (public key) 與指紋 (fingerprint) 會自動推導出來。

### 透過 CLI 腳本

此 repo 提供匯入腳本（見 [import_ssh_to_bw.sh 文件](../this_repo/scripts/import_ssh_to_bw.sh.md)）：

```bash
# 互動式 -- 挑選要匯入的金鑰
ssh-to-bitwarden

# 從 ~/.ssh 匯入所有金鑰
ssh-to-bitwarden --all

# 僅預覽
ssh-to-bitwarden --dry-run
```

## 2. 設定 SSH_AUTH_SOCK

socket 路徑取決於 Bitwarden 的安裝方式：

| 安裝方式       | macOS socket 路徑                                                                         | Linux socket 路徑                                                       |
|----------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `.dmg`         | `~/.bitwarden-ssh-agent.sock`                                                             | --                                                                      |
| Mac App Store  | `~/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock`               | --                                                                      |
| Native / .deb  | --                                                                                        | `~/.bitwarden-ssh-agent.sock`                                           |
| Snap           | --                                                                                        | `~/snap/bitwarden/current/.bitwarden-ssh-agent.sock`                    |
| Flatpak        | --                                                                                        | `~/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock`       |

此 repo 在 `~/.config/zsh/tools/94_ssh_agent.zsh` 自動偵測 socket。
它會依序嘗試各個候選路徑，並對第一個存在**且有回應**的 socket 匯出 `SSH_AUTH_SOCK`。
如果你使用此 repo 管理的 zsh 設定，無需任何手動 shell 組態 (configuration)。

### 自動備援 (Automatic Fallback)

如果 Bitwarden desktop 沒有執行（或其 socket 已失效），agent 腳本會自動退回使用持久化的 `ssh-agent`，並從 `~/.ssh/` 載入金鑰。
完整的備援鏈詳見 [SSH Agent Fallback](../tools/ssh-agent.md)。

## 3. 驗證

```bash
# 列出 agent 已知的金鑰
ssh-add -l

# 預期輸出（範例）:
# 3072 SHA256:S93TIv0W2E1B...  SSH: ssh_key_1 (RSA)
# 3072 SHA256:B7ZcVqELH0RQ...  SSH: ssh_key_2 (RSA)
# 3072 SHA256:i+mZs1/NiKo+...  SSH: ssh_key_3 (RSA)

# 測試 GitHub 驗證 (authentication)
ssh -T git@github.com
# Hi daviddwlee84! You've successfully authenticated, ...
```

如果 `ssh-add -l` 回傳 "The agent has no identities"，請檢查：

1. Bitwarden desktop 已啟動且已解鎖。
2. **Settings** 內已啟用 SSH agent。
3. `SSH_AUTH_SOCK` 指向正確的 socket（`echo $SSH_AUTH_SOCK`）。

## 4. 與 ~/.ssh/config 的互動

### SSH 如何選擇金鑰

SSH 依下列順序嘗試金鑰：

1. `~/.ssh/config` 中由 `IdentityFile` 指定的金鑰（直接從磁碟讀取）。
2. agent 提供的金鑰（`SSH_AUTH_SOCK`）。

這代表使用 Bitwarden 作為 agent 時，兩種來源能並存：

- 如果磁碟上存在 `IdentityFile ~/.ssh/jingle`，SSH 會直接使用它（不經過 agent）。
- 如果該檔案不存在，或其金鑰被拒絕，SSH 會退回使用 Bitwarden agent 提供的金鑰。

### 建議的設定模式

#### 保留 IdentityFile（本機檔案優先，Bitwarden 作為備援）

這是最安全的遷移路徑。你既有的設定不需任何修改即可運作。
若你日後刪除本機金鑰檔案，Bitwarden agent 會無縫接手：

```ssh-config
# ~/.ssh/config

Host github.com
    HostName github.com
    IdentityFile ~/.ssh/jingle      # 若磁碟上有此檔案就使用它
                                     # Bitwarden agent 為備援

Host azure
    HostName <vm>.<region>.cloudapp.azure.com
    User daviddwlee84
    Port 22
    IdentityFile ~/.ssh/YetAnotherStupidVM
```

#### 僅使用 agent（不需要本機金鑰檔案）

如果你想完全依賴 Bitwarden 並從磁碟移除私鑰：

```ssh-config
# ~/.ssh/config

Host github.com
    HostName github.com
    # 不設 IdentityFile -- agent 會自動提供正確的金鑰

Host azure
    HostName <vm>.<region>.cloudapp.azure.com
    User daviddwlee84
    Port 22
    # 不設 IdentityFile -- agent 會自動提供正確的金鑰
```

SSH 會逐一嘗試 agent 中的每把金鑰，直到伺服器接受其中一把為止。

#### 透過指紋鎖定特定金鑰（僅 agent，明確指定）

如果你的 agent 內有許多金鑰，並想避免逐一嘗試的耗時，
可使用 `IdentityFile` 搭配公鑰檔案（`.pub` 檔案保留在磁碟上是安全的）：

```ssh-config
Host github.com
    HostName github.com
    IdentityFile ~/.ssh/jingle.pub
    IdentitiesOnly yes
```

加上 `IdentitiesOnly yes` 後，SSH **只會**向 agent 索取對應的金鑰
（以公鑰識別），不會嘗試其他金鑰。當伺服器限制驗證次數時特別有用。

### 應該避免的寫法

```ssh-config
# 別在使用 agent 時把 IdentitiesOnly 與沒有 IdentityFile 的設定放在一起
Host example
    IdentitiesOnly yes
    # 沒有 IdentityFile = 完全不會嘗試任何金鑰！
```

`IdentitiesOnly yes` 在沒有 `IdentityFile` 時會完全停用 agent 的金鑰提供。

## 5. 用 SSH 簽署 Git commit

Bitwarden SSH 金鑰也能用來簽署 Git commit：

```bash
# 設定 Git 使用 SSH 簽署
git config --global gpg.format ssh
git config --global user.signingkey "ssh-rsa AAAAB3Nza..."  # 你的公鑰
git config --global commit.gpgsign true
```

在 GitHub 上，把同一把公鑰新增為 **Signing Key**（與 Authentication Key 分開），
位置在 **Settings > SSH and GPG keys**。

## 6. SSH Agent 轉發 (Forwarding)

使用 `-A` 將 Bitwarden agent 轉發到遠端主機 (host)：

```bash
ssh -A user@remote-host
```

或在 `~/.ssh/config` 中設定：

```ssh-config
Host myserver
    HostName 192.168.1.100
    User admin
    ForwardAgent yes
```

如此一來，遠端主機便能使用你 Bitwarden 管理的金鑰繼續向其他服務驗證
（例如在遠端 server 上執行 `git pull`），私鑰永遠不會離開你的本機。

## 疑難排解 (Troubleshooting)

| 症狀 | 原因 | 解法 |
|---|---|---|
| `ssh-add -l` 回傳 "no identities" | Bitwarden 鎖定或 agent 未啟用 | 解鎖 Bitwarden，並在 Settings 啟用 SSH agent |
| `ssh-add -l` 回傳 "connection refused" | socket 路徑錯誤 | 檢查 `echo $SSH_AUTH_SOCK`，並 `ls -la` 該路徑 |
| SSH 使用了錯誤的金鑰 / 驗證失敗次數過多 | 在試到正確金鑰之前 agent 嘗試了太多金鑰 | 加上 `IdentityFile` 指向 `.pub` 並設 `IdentitiesOnly yes` |
| Git commit 簽署失敗 | `user.signingkey` 未設定或設錯 | 用 `git config --global user.signingkey` 確認 |
| agent 在終端機正常但 IDE 無法使用 | IDE 使用自己的環境 | 在 IDE 設定中設定 `SSH_AUTH_SOCK`，或從終端機啟動 IDE |
| Bitwarden 已關閉但 SSH 仍能運作 | 備援 ssh-agent 接手了（預期行為） | 見 [SSH Agent Fallback](../tools/ssh-agent.md) |
| 在**遠端/無頭**session 上 `git push`/`ssh` 失敗 `Connection closed by … port 443` + `Could not read from remote repository`；時好時壞（第一次成功、之後失敗） | 桌面的「Confirm SSH key usage」確認框彈在機器的**實體螢幕**上，你透過 SSH/tmux 按不到，agent 因而拒絕簽署（授權會短暫快取 → 第一次成功、之後失敗） | 到實體螢幕按確認；**或**在 **Settings → SSH agent** 關閉每次使用需確認；**或**從可點擊的機器轉發 agent（`ssh -A`）；**或** git 改用 HTTPS+PAT。完整說明：`pitfalls/bitwarden-ssh-agent-confirm-blocks-remote-git-push.md` |

## 相關連結

- [SSH Agent Fallback](../tools/ssh-agent.md) -- 備援鏈：Bitwarden → 既有 agent → ssh-agent
- [Bitwarden SSH Agent 官方文件](https://bitwarden.com/help/ssh-agent/)
- [import_ssh_to_bw.sh](../this_repo/scripts/import_ssh_to_bw.sh.md) -- 大量匯入 SSH 金鑰到 Bitwarden
- `~/.config/zsh/tools/94_ssh_agent.zsh` -- SSH agent 自動偵測與備援
- `~/.config/zsh/tools/95_bitwarden.zsh` -- Bitwarden CLI zsh 補全 (completion)
