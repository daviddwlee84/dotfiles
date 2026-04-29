# Linux Locale Configuration

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

## 什麼是 Locale？

Locale（地區設定）定義了系統的語言、地區格式 (regional formatting) 與字元編碼 (character encoding) 偏好。它影響程式如何顯示文字、排序字串、格式化日期 / 數字 / 貨幣、以及處理字元編碼。

## Locale 類別

每個類別控制 localization 的某個面向：

| 變數 | 控制 | 範例效果 |
|----------|----------|----------------|
| `LANG` | 所有類別的預設值 | Base fallback locale |
| `LC_CTYPE` | 字元分類 (character classification)、大小寫轉換 | 哪些字元算字母、`toupper()` 行為 |
| `LC_COLLATE` | 字串排序順序 | `sort` 排序（例：`a < B` vs `A < a < B`） |
| `LC_MESSAGES` | 系統訊息語言 | 錯誤訊息用英文還是中文 |
| `LC_NUMERIC` | 數字格式 | `1,234.56`（US）vs `1.234,56`（DE） |
| `LC_TIME` | 日期 / 時間格式 | `04/16/2026` vs `16.04.2026` |
| `LC_MONETARY` | 貨幣格式 | `$1,234` vs `1.234 €` |
| `LC_PAPER` | 預設紙張大小 | Letter（US）vs A4（EU） |
| `LC_NAME` | 姓名格式慣例 | 名前姓後 vs 姓前名後 |
| `LC_ADDRESS` | 地址格式 | 各國郵政格式 |
| `LC_TELEPHONE` | 電話號碼格式 | 國碼慣例 |
| `LC_MEASUREMENT` | 度量衡系統 | 英制 vs 公制 |
| `LC_IDENTIFICATION` | Locale metadata | Locale 自身的描述 |
| `LC_ALL` | **凌駕以上所有** | 核選項 (nuclear option) ——一次設定所有類別 |
| `LANGUAGE` | GNU gettext 訊息優先順序清單 | 翻譯的 fallback chain |

**注意**：Locale **不**控制時區。時區用 `TZ` 環境變數或 `/etc/timezone` 設定。

## 優先順序

當程式查詢某個類別的 locale 時：

```
LC_ALL  →  LC_<CATEGORY>  →  LANG
(highest)                     (lowest)
```

- `LC_ALL` 凌駕一切——若已設定，個別 `LC_*` 變數會被忽略
- 個別 `LC_*` 變數凌駕該類別的 `LANG`
- `LANG` 是預設 fallback

**最佳實踐**：把 `LANG` 設為偏好的 locale，個別 `LC_*` 只用於選擇性覆寫。永久設定中避免用 `LC_ALL`——它是給一次性指令用的。

## 常見 Locale 值

| Locale | 說明 |
|--------|-------------|
| `C` 或 `POSIX` | 最小 ASCII locale，無 UTF-8，最快 |
| `C.UTF-8` | ASCII 排序 + UTF-8 編碼（安全的通用預設） |
| `en_US.UTF-8` | 美式英文 + UTF-8 |
| `en_GB.UTF-8` | 英式英文 + UTF-8 |
| `zh_TW.UTF-8` | 繁體中文（台灣）+ UTF-8 |
| `ja_JP.UTF-8` | 日文 + UTF-8 |

格式為：`language_TERRITORY.ENCODING`

## 檢查目前 Locale

```bash
# 顯示所有 locale 變數
locale

# 列出所有已安裝 / 已產生的 locale
locale -a

# 檢查特定 locale 是否存在
locale -a | grep en_US
```

## 產生 Locale（Debian / Ubuntu）

Locale 必須先**產生 (generate)** 才能使用。如果設了 `LC_ALL=en_US.UTF-8` 但該 locale 尚未產生，每個指令都會印出警告：

```
locale: Cannot set LC_CTYPE to default locale: No such file or directory
locale: Cannot set LC_ALL to default locale: No such file or directory
```

### 修正：產生缺失的 Locale

```bash
# 方法 1：在 /etc/locale.gen 取消註解後產生
sudo sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sudo locale-gen

# 方法 2：直接產生（Debian / Ubuntu）
sudo locale-gen en_US.UTF-8

# 方法 3：互動式重新設定 (interactive reconfiguration)
sudo dpkg-reconfigure locales
```

### 設定系統預設 Locale

```bash
# 永久預設（寫入 /etc/default/locale）
sudo update-locale LANG=en_US.UTF-8

# 或直接編輯
echo 'LANG=en_US.UTF-8' | sudo tee /etc/default/locale
```

## Locale 在哪裡設定

| 來源 | 範圍 | 檔案 |
|--------|-------|------|
| 系統預設 | 所有使用者 | `/etc/default/locale` |
| PAM（登入） | 登入 session | `/etc/pam.d/common-session` 讀取 `/etc/default/locale` |
| SSH `SendEnv` | 遠端 session | Client 的 `~/.ssh/config` 或 `/etc/ssh/ssh_config` |
| SSH `AcceptEnv` | 遠端 session | Server 的 `/etc/ssh/sshd_config` |
| Shell profile | 目前使用者 | `~/.bashrc`、`~/.zshrc`、`~/.profile` |
| Systemd | 服務 | `/etc/systemd/system.conf` 中的 `DefaultEnvironment=` |

### SSH Locale Forwarding（常見陷阱）

SSH client 通常會把本機的 `LC_*` 變數轉發到遠端主機。如果本機設定 `LC_ALL=en_US.UTF-8` 但遠端伺服器沒產生這個 locale，每次 SSH 指令都會出現 locale 警告。

流程：
```
Local: LC_ALL=en_US.UTF-8 → SSH SendEnv LC_* → Remote: 試 en_US.UTF-8 → 未產生 → 警告
```

**修正選項：**

1. 在遠端伺服器上產生該 locale（見上方）
2. 停止轉發：移除本機 `/etc/ssh/ssh_config` 的 `SendEnv LANG LC_*`
3. 停止接受：移除遠端 `/etc/ssh/sshd_config` 的 `AcceptEnv LANG LC_*`
4. 在遠端 shell profile 覆寫：`export LC_ALL=C.UTF-8`

## 對工具的影響

### Python / Ansible

Python 的 `locale.setlocale()` 在請求的 locale 不存在時會丟錯誤。Ansible 特別要求 UTF-8 編碼：

```
ERROR: Ansible could not initialize the preferred locale: unsupported locale setting  # locale missing
ERROR: Ansible requires the locale encoding to be UTF-8; Detected None.              # LC_ALL=C (no UTF-8)
```

**腳本的安全 fallback**：`export LC_ALL=C.UTF-8`

### 排序（coreutils）

```bash
# C locale：ASCII byte 順序（A-Z 在 a-z 之前）
LC_COLLATE=C sort <<< $'banana\nApple\napricot'
# → Apple, apricot, banana

# en_US locale：不分大小寫的字典順序
LC_COLLATE=en_US.UTF-8 sort <<< $'banana\nApple\napricot'
# → Apple, apricot, banana  (可能不同)
```

### 正規表示式 (Regular Expressions)

`[a-z]` 在 `C` locale 只比對小寫 ASCII。在 `en_US.UTF-8` 中可能包含帶重音符 (accented) 的字元。要可攜行為請用 `[[:lower:]]`。

## Raspberry Pi 注意事項

Raspberry Pi OS 常常設定了 `LC_ALL=en_US.UTF-8`（透過 SSH 轉發或預設設定），但實際上沒產生該 locale。Kernel 可能回報 `aarch64`，而 userland 是 32-bit `armhf`，但這跟 locale 無關——locale 純粹是 userland 概念。

RPi locale 警告的快速修法：

```bash
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8
```

## 這個 Dotfiles Repo

Bootstrap script (`run_once_before_00_bootstrap.sh.tmpl`) 偵測損壞的 locale，並在執行 Ansible 前 fallback 到 `C.UTF-8`。Ansible onchange script (`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`) 為了相同原因無條件 export `LC_ALL=C.UTF-8`。
