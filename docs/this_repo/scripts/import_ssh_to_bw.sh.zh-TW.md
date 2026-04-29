# import_ssh_to_bw.sh

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

使用 `bw` CLI 將 SSH 金鑰對 (key pair) 匯入 Bitwarden 保險庫 (vault)。

## 需求

- `bw`（Bitwarden CLI >= 2024.x）—— 提供 SSH Key 項目類型 (item type 5)
- `jq` —— 用於建構 JSON 載荷 (payload) 與解析回應
- `ssh-keygen` —— 用於擷取指紋 (fingerprint) 與金鑰類型

## 運作方式

1. **探索 (discovery)** —— 掃描 `~/.ssh`（或自訂目錄），尋找以 `-----BEGIN...PRIVATE KEY-----` 開頭的檔案。會略過 `.pub`、`known_hosts`、`config`、`authorized_keys`、swap files 等。
2. **詮釋資料 (metadata) 擷取** —— 對每個私鑰 (private key)，尋找對應的 `.pub` 檔（會嘗試 `<key>.pub` 與 `<stem>.pub`）。透過 `ssh-keygen -lf` 擷取指紋、金鑰類型與註解 (comment)。
3. **互動式選擇** —— 顯示已發現金鑰的表格，並提示使用者選擇要匯入哪些（依編號、`a` 全選、`q` 結束）。
4. **重複偵測** —— 在建立項目前，會檢查保險庫中是否已存在同名項目。在互動模式下會詢問是否覆寫；在 `--all` 模式下會略過重複項。
5. **匯入** —— 建立 Bitwarden **SSH Key 項目** (type 5)，包含私鑰、公鑰 (public key) 與指紋。若無法擷取指紋，則退回至 **Secure Note** (type 2)。

## 用法

```bash
ssh-to-bitwarden [OPTIONS]
```

### 選項

| Flag | 說明 |
|---|---|
| `-d, --dir DIR` | 要掃描的目錄（預設：`~/.ssh`） |
| `-a, --all` | 直接匯入所有找到的金鑰，不再詢問 |
| `-n, --dry-run` | 顯示會匯入哪些項目，但不實際建立 |
| `-p, --prefix STR` | Bitwarden 項目名稱的前綴（預設：`SSH`） |
| `-h, --help` | 顯示說明訊息 |

### 範例

```bash
# 互動模式 -- 掃描 ~/.ssh，挑選要匯入的金鑰
./import_ssh_to_bw.sh

# 不詢問，匯入所有
./import_ssh_to_bw.sh --all

# 預覽會匯入哪些項目
./import_ssh_to_bw.sh --dry-run

# 掃描其他目錄
./import_ssh_to_bw.sh --dir /path/to/keys

# 使用自訂名稱前綴（項目會命名為 "Work SSH: <keyname>"）
./import_ssh_to_bw.sh --prefix "Work SSH"
```

## Bitwarden 項目類型

| 條件 | Bitwarden 類型 | 備註 |
|---|---|---|
| 可擷取指紋 | SSH Key (type 5) | 原生儲存私鑰、公鑰與指紋 |
| 無法擷取指紋 | Secure Note (type 2) | 退回方案，將私鑰存放於 notes 欄位 |

項目命名為 `<prefix>: <filename>`（例如 `SSH: azure_vm1`、`SSH: Puff.pem`）。

## 注意事項

- `bw unlock` 步驟需要互動式輸入密碼，因此本腳本必須直接在終端機 (terminal) 中執行（不可在非互動式 shell 中執行）。
- 你必須先登入 (`bw login`)。若保險庫狀態為 `unauthenticated`，腳本會回報錯誤。
- 使用 `--all` 時，現有的重複項目會被略過而非覆寫。若要覆寫，請使用互動模式。
- 金鑰會在選擇表格中依檔名按字母順序排序。
