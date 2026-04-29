# chezmoi 來源狀態前置詞 (Source-State Prefixes)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本頁是 chezmoi 在來源目錄 (source directory) 中用來編碼目標 (target) 中繼資料的檔名前置詞 (filename prefix)（`dot_`、`private_`、`create_`、`modify_`……）的實用參考，並附帶一張帶有立場的「能否安全 `chezmoi add`？」決策表，以及為本 repo 量身打造的操作指南。

## 官方參考

- [Source state attributes](https://www.chezmoi.io/reference/source-state-attributes/) — 完整的前置詞與後置詞清單，以及每種目標類型允許的排序順序。這是真理來源 (source of truth)；瀏覽過一次後加入書籤即可。
- [Manage different types of file](https://www.chezmoi.io/user-guide/manage-different-types-of-file/) — 實作配方 (recipe)，包含 [Manage part, but not all, of a file](https://www.chezmoi.io/user-guide/manage-different-types-of-file/#manage-part-but-not-all-of-a-file)（`modify_` 模式）以及 create-only 種子化 (seeding)。
- [`chezmoi chattr`](https://www.chezmoi.io/reference/commands/chattr/) — 不需要手動重新命名檔案就能切換前置詞（例如 `chezmoi chattr +create,+private ~/.ssh/config`）。

## `chezmoi add` 安全性決策表

當實際檔案 (live file) 與來源分歧、你想要重新同步時，第一個要問的問題是：「這個前置詞屬於哪一類？」**前置詞會改變 `chezmoi add` / `re-add` 的語意 (semantics)** —— 這個指令並不是單純的複製。

| 類別 | 前置詞 | `chezmoi add <target>` 的行為 | 行動 |
|---|---|---|---|
| 綠燈通行 | `dot_`、`private_`、`executable_`、`readonly_`、`empty_` | 以實際檔案內容覆寫來源檔案，前置詞會被保留。 | 可自由使用。 |
| 可加入但需重新檢視語意 | `create_`、`exact_`、`literal_` | 可以運作，但可能**默默改變語意契約 (semantic contract)**（見下方註解）。 | 使用後 `git diff` 來源檔名，確認前置詞仍是你預期的樣子。 |
| 不要當成一般受追蹤檔案處理 | `modify_`、`encrypted_`、`remove_`、`symlink_`、scripts (`run_*`) | `chezmoi add` 會剝除前置詞，或用實際資料覆寫腳本內容。 | 直接編輯來源檔案，或使用 `cp "$(chezmoi source-path <target>)"` / `chezmoi edit`。 |

中間類別的補充說明：

- `create_`：`chezmoi add` 會**剝除** `create_` 前置詞，將原本只用於種子化的檔案默默升級為完全受管理的檔案。`chezmoi re-add` 對 `create_` 是無作用的（這是設計上的選擇 —— 初次 create 之後內容就不再受管理）。
- `exact_`（僅限目錄）：在 `exact_` 目錄裡新增檔案沒問題，但要記得下次 apply 時，目錄會修剪掉所有不在來源中的東西。
- `literal_`：它的重點就是抑制屬性解析。新增一個同名的檔案會重新解析前置詞 —— 你可能需要手動重新命名。

## 各前置詞參考

每個條目都連結到 [Source state attributes](https://www.chezmoi.io/reference/source-state-attributes/) 中的對應行。

### `dot_` — 開頭加上點 (rename)

- **效果**：來源中的 `dot_foo` 變成目標的 `.foo`。純粹是名稱對映，讓 dotfile 在 `git ls-files` 中保持可見。
- **`chezmoi add`**：綠燈通行。
- **典型用途**：`dot_zshrc`、`dot_gitconfig`、`dot_config/…`、`dot_ssh/…`。

### `private_` — 收緊檔案模式為 0600（目錄為 0700）

- **效果**：移除目標的 group / world 權限。每次 `chezmoi apply` 都會強制執行。
- **`chezmoi add`**：綠燈通行。對已是 0600 模式的檔案執行 `chezmoi add` 時，會自動為你編入 `private_`。
- **風險**：這只是權限位元 (permission bit) —— 它**不會**加密檔案。把含有秘密 (secrets) 的 `private_` 檔案 commit 進去，仍然是用明文 commit 的。如果是秘密，請使用 `encrypted_` 或密碼管理器 (password manager) 樣板函式 (template function)。
- **典型用途**：`private_dot_ssh/config`、`private_dot_netrc`、含有帳號提示的 Claude Code 設定檔。

### `executable_` — 加上 +x bit

- **效果**：確保目標每次 apply 都帶有可執行位元 (executable bit)。
- **`chezmoi add`**：綠燈通行。當你新增一個已具備 +x 的檔案時會自動偵測。
- **典型用途**：`~/bin/` 或 `~/.local/bin/` 下的個人腳本（例如 `executable_x`、`executable_sms`）、輔助包裝器 (wrapper)、`~/.local/share/tmux-*` 的 shim。

### `readonly_` — 移除所有寫入位元

- **效果**：移除目標的寫入權限。每次 apply 都會執行，所以即使你 `chmod +w`，檔案也會被重設為唯讀。
- **`chezmoi add`**：綠燈通行，但要注意 re-add 可能會很煩，因為你必須先在本機 `chmod +w`。
- **典型用途**：你不希望被誤改的凍結基線 (frozen baseline)。在個人 dotfiles repo 中很少有用。

### `create_` — 種子化一次後便不再過問

- **效果**：**僅在目標不存在時**才寫入檔案。之後 chezmoi 不再過問內容。
- **`chezmoi add`**：請小心使用 —— `chezmoi add` 會**剝除** `create_` 前置詞，這會默默把檔案升級為一般受管理檔案（喪失 seed-only 契約）。
- **`chezmoi re-add`**：刻意**跳過** `create_` 檔案。
- **更新基線的配方**：要更新基線，請把實際檔案複製到來源路徑（這樣會保留前置詞）：

  ```bash
  cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"
  ```

- **典型用途**：LazyVim `lazy-lock.json`（見[下方案例研究](#dot_confignvimcreate_lazy-lockjson--seed-once-never-overwrite)）、SSH `config` 骨架、首次執行的應用程式基線。

### `modify_` — 內容是腳本，不是檔案

- **效果**：來源檔案是一個可執行的**腳本**。chezmoi 把目前的目標內容透過 stdin 餵給腳本；腳本把新的目標內容寫到 stdout。讓你能管理檔案的一部分（例如透過 `jq`、`sed`、`awk`），其餘部分保持不動。
- **`chezmoi add`**：**不要**對 `modify_` 目標執行 `chezmoi add` —— 它會用實際檔案內容覆寫你的腳本。
- **替代寫法**：在腳本主體中加入 `chezmoi:modify-template` 切換到樣板模式（目前內容會以 `.chezmoi.stdin` 形式傳入）。見 [Manage part, but not all, of a file](https://www.chezmoi.io/user-guide/manage-different-types-of-file/#manage-part-but-not-all-of-a-file)。
- **典型用途**：Claude Code `settings.json`（見[下方案例研究](#dot_claudemodify_settingsjson--partial-json-management-via-jq)）、Docker `config.json` proxy、混合受管理鍵與執行階段 (runtime) 寫入鍵的 INI 檔案。

### `exact_` — 目錄具權威性（修剪多餘檔案）

- **效果**：apply 時，chezmoi 會**移除**目標目錄中任何不在來源中的檔案。僅限目錄前置詞。
- **`chezmoi add`**：對目錄內個別檔案是安全的，但要注意語意陷阱 —— 下次 apply 會清掉任何漂入 (drift in) 的東西。
- **風險**：很容易意外刪除恰好住在該目錄裡的本機產物（快取 (cache)、外掛安裝等）。
- **典型用途**：你真正端對端擁有、且小而穩定的目錄。請避免用在混雜受管理設定與執行階段狀態的目錄。

### `literal_` — 停止解析屬性

- **效果**：告訴 chezmoi 停止把後續檔名當成屬性解釋。當實際檔名以 `create` 或 `run` 之類字串開頭、而你希望 chezmoi 按字面處理時使用。
- **`chezmoi add`**：綠燈通行，但要記得這個前置詞之所以存在是檔名層級的原因 —— 之後盲目重新命名可能會破壞對映。
- **典型用途**：罕見。處理檔名中字面上的 `run_` 或 `dot_` 等邊角情況。

### `remove_` — 主張移除

- **效果**：宣告目標應該**不存在**。apply 時，如果檔案 / 符號連結 (symlink)（或空目錄）存在，chezmoi 會將其移除。來源檔案的內容並非內容來源 —— 它是「存在性主張 (presence assertion)」。
- **`chezmoi add`**：不適用（沒有實際內容可同步回來）。
- **典型用途**：在遷移工具後清理過時設定。經常與樣板 (template) 結合，使其只在特定主機上觸發。

### `encrypted_` — 靜態加密 (encrypt at rest)

- **效果**：來源檔案以加密形式儲存（age 或 gpg，取決於 `encryption` 設定）。chezmoi 會在 apply 時解密。磁碟上的後置詞為 `.age` 或 `.asc`（在目標中會被剝除）。
- **`chezmoi add`**：支援（chezmoi 會重新加密），但這只在你已決定採用秘密管理工作流（age key、gpg 設定）時才有意義。
- **替代方案**：使用樣板函式（`onepassword`、`bitwarden`、`keyring`、`vault`……）在 apply 時擷取秘密，而不是把加密版本 commit 進來。
- **典型用途**：少數你想保留在 repo 歷史中的憑證檔案。

### `symlink_` — 建立符號連結而非檔案

- **效果**：目標是一個符號連結，其內容為來源檔案的第一行（通常是會展開成路徑的樣板）。
- **`chezmoi add`**：對既有的符號連結執行 add 會自動產生 `symlink_` 來源。
- **典型用途**：把 dotfile 指向外部管理的檔案（`~/.config/Code/User/settings.json` → `{{ .chezmoi.sourceDir }}/settings.json`，見官方處理外部修改設定的配方）。

### `empty_` — 允許空檔案

- **效果**：預設 chezmoi 會移除零位元組檔案；`empty_` 表示「這個檔案是刻意留空的」。
- **典型用途**：標記檔案、空的 `.hushlogin`。

### `external_` — 不解析子項屬性

- **效果**：僅限目錄。停止 chezmoi 對其中檔案進行屬性解析。通常與 `.chezmoiexternal.<format>` 來源搭配，後者會傳遞整個子樹 (subtree)。
- **典型用途**：vendored 外掛目錄、`git-repo` 外部資源。
- **配套檔案**：repo 根目錄的 `.chezmoiexternal.<format>`（見本 repo 的 [`.chezmoiexternal.toml.tmpl`](../../.chezmoiexternal.toml.tmpl) 以及下方對應段落）。

### 腳本族 — `run_`、`once_`、`onchange_`、`before_`、`after_`

- **效果**：來源檔案是 chezmoi 在 apply 時執行的**腳本**。不會建立目標檔案。修飾字 (modifier) 可以組合：
  - `run_` — 基本標記。
  - `once_` — 同一個腳本主體 (script body) 只跑一次（以 hash 作為鍵）。
  - `onchange_` — 當腳本主體變動時執行（以檔名為鍵；和 `once_` 不同，編輯腳本會使其重跑）。
  - `before_` / `after_` — 在 apply 目標檔案之前 / 之後執行。
- **`chezmoi add`**：不適用 —— 腳本沒有檔案目標。
- **本 repo 已存在**：`run_once_before_00_bootstrap.sh.tmpl`、`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`、`.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`。詳見 [docs/this_repo/architecture.md → Auto-run scripts](../this_repo/architecture.md#auto-run-scripts)。

## 允許的前置詞排序

當多個前置詞同時生效時，順序很重要。摘自 [Source state attributes](https://www.chezmoi.io/reference/source-state-attributes/)：

| 目標類型 | 允許的前置詞（依順序） | 允許的後置詞 |
|---|---|---|
| Directory | `remove_`、`external_`、`exact_`、`private_`、`readonly_`、`dot_` | — |
| Regular file | `encrypted_`、`private_`、`readonly_`、`empty_`、`executable_`、`dot_` | `.tmpl` |
| Create file | `create_`、`encrypted_`、`private_`、`readonly_`、`empty_`、`executable_`、`dot_` | `.tmpl` |
| Modify file | `modify_`、`encrypted_`、`private_`、`readonly_`、`executable_`、`dot_` | `.tmpl` |
| Remove file | `remove_`、`dot_` | — |
| Script | `run_`、(`once_` 或 `onchange_`)、(`before_` 或 `after_`) | `.tmpl` |
| Symlink | `symlink_`、`dot_` | `.tmpl` |

實作範例：

- `private_executable_dot_ssh/private_readonly_id_ed25519` — 目錄為 private，檔案為 private+readonly。（實務上：不要把私鑰 commit 進去；此處只為展示順序。）
- `create_private_dot_ssh/create_private_config` — 建立時為 0600 的 create-once SSH 設定。
- `modify_private_dot_claude/modify_settings.json` — 本 repo 實際使用的模式（見[下方案例研究](#dot_claudemodify_settingsjson--partial-json-management-via-jq)）。

如果不小心把堆疊順序弄錯，`chezmoi chattr` 會幫你規範化：

```bash
chezmoi chattr +private,+readonly ~/.config/foo/bar
```

## 操作指南：本 repo 的應用場景

### A. 日常設定 — `dot_`（敏感的話加 `private_`）

正常追蹤、自由 `chezmoi add`，讓 `chezmoi re-add` 自動撈取 drift。

- `dot_zshrc`、`dot_gitconfig`、`dot_tmux.conf`、`dot_config/nvim/lua/*`、`dot_config/starship.toml`、`dot_config/tmux/*`、`dot_config/zsh/tools/*`、`dot_config/sesh/*`、`dot_config/zellij/*`……
- 半敏感（帳號提示，但不是秘密）：加上 `private_`（例如 `private_dot_ssh/…`、`private_dot_claude/…`）。

### B. 個人腳本 — `executable_`（必要時加 `dot_`）

- `~/bin/sms` → 來源中為 `executable_sms`。
- `~/.local/bin/x` → 位於 `dot_local/bin/executable_x`。
- 任何你希望放在 PATH 上的輔助 shell 腳本。

### C. 一次性種子化基線 — `create_`

由 app 在首次啟動後在原處重寫的檔案，且你只在乎初始狀態。

- **`~/.config/nvim/lazy-lock.json`** → `create_lazy-lock.json`。見[下方案例研究](#dot_confignvimcreate_lazy-lockjson--seed-once-never-overwrite)。以 `cp … "$(chezmoi source-path …)"` 更新基線。
- **`~/.ssh/config`** → 一個 create-only 樣板，內容為 `Include ~/.ssh/config.d/*` 並提供保守的預設值。詳見 [README.md](../../README.md) 中的 SSH 說明。
- 首次執行的 app JSON，後續變更為 user-local（state 與偏好混雜的設定檔）。

### D. 部分內容管理 — 透過腳本的 `modify_`

由 app 在執行階段主動重寫（新增鍵、重新排序……）的檔案，但你只想強制其中部分鍵。

- **`~/.claude/settings.json`** → `dot_claude/modify_settings.json`，一個用 `jq` 深度合併 (deep-merge) 受管理覆蓋層 (overlay) 的腳本。見[下方案例研究](#dot_claudemodify_settingsjson--partial-json-management-via-jq)。
- **`~/.docker/config.json`** → 一個 modify 腳本，重寫 `proxies.default` 同時保留 `auths` / `credsStore`。見 [docs/tools/containers.md](containers.md)。
- 經驗法則：如果 app 擁有檔案，而你只在乎 N 個鍵，`modify_` 比完整受管理樣板更划算。

### E. 本機 / 執行階段 / 快取 — `.chezmoiignore`，而非前置詞

**不要**用 `create_` 嘗試追蹤這些檔案。它們屬於 `.chezmoiignore` 或乾脆放在來源樹之外。

- 編輯器 swap / shada / session 檔
- 外掛安裝產物（LazyVim 外掛原始碼、tmux TPM repo……）
- 日誌、快取、`lazy-install.log`、`.DS_Store`
- 各主機執行階段狀態

### F. 秘密 — 偏好樣板而非 `encrypted_`

本 repo 中處理秘密的偏好順序：

1. **樣板函式**，在 apply 時擷取：`{{ bitwarden … }}`、`{{ onepassword … }}`、`{{ keyring … }}`、`{{ vault … }}`。沒有任何秘密進入 git。
2. **`encrypted_`** 搭配 age 或 gpg，如果你需要把值放在 repo 中（例如離線機器）。請先設好 `encryption` 與 key 工作流，再 commit。
3. **絕不**用一般的 `private_` 檔案 commit 真實 token —— `private_` 只是權限位元，不是加密。

## 更新 / 維護配方

### `chezmoi re-add` vs `chezmoi add`

| 情境 | 指令 |
|---|---|
| 檔案已被追蹤，僅撈取 drift | `chezmoi re-add <target>`（保留前置詞，遇 `modify_` 大聲失敗，遇 `create_` 默默跳過） |
| 首次新增檔案 | `chezmoi add <target>` |
| 更新 `create_` 基線 | `cp <target> "$(chezmoi source-path <target>)"` |
| 更新 `modify_` 腳本 | 直接編輯來源腳本（`chezmoi edit <target>`） |
| 變更既有來源檔案的前置詞 | `chezmoi chattr +create,+private <target>`（或 `-executable` 等） |

### commit 前預覽

```bash
chezmoi diff <target>           # 看目標 diff
chezmoi apply --dry-run -v      # 看本機若實際 apply 會怎樣
chezmoi status                  # 哪些檔案處於 A/M/D 狀態
```

### 當 `chezmoi add` 看起來「做錯了事」

最常見的情況是前置詞被默默剝除：

```bash
chezmoi source-path <target>    # 它住在哪裡？
ls "$(dirname "$(chezmoi source-path <target>)")"  # 檢視鄰居 —— 前置詞是不是消失了？
chezmoi chattr +create <target> # 把它加回來
```

對 `modify_` 目標，從 git 倒回腳本：

```bash
git -C "$(chezmoi source-path)" checkout -- <relative/path/to/modify_file>
```

## 配套檔案：`.chezmoiexternal.<format>`

它不是前置詞，而是 repo 層級的配套機制：repo 根目錄的單一宣告檔案，告訴 chezmoi 把上游內容（git repo、單一檔案、archive）抓進目標樹。參考：[Include files from elsewhere](https://www.chezmoi.io/user-guide/include-files-from-elsewhere/) 與 [`.chezmoiexternal.<format>` reference](https://www.chezmoi.io/reference/special-files-and-directories/chezmoiexternal-format/)。

### 本 repo：[`.chezmoiexternal.toml.tmpl`](../../.chezmoiexternal.toml.tmpl)

過去住在 ansible role 中、現在改由此處作為真理來源的上游 clone。目前的條目：

| 目標 | 類型 | URL | 過去位於 |
|---|---|---|---|
| `~/.oh-my-zsh` | `git-repo` | `ohmyzsh/ohmyzsh` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions` | `git-repo` | `zsh-users/zsh-autosuggestions` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting` | `git-repo` | `zsh-users/zsh-syntax-highlighting` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-completions` | `git-repo` | `zsh-users/zsh-completions` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-vi-mode` | `git-repo` | `jeffreytse/zsh-vi-mode` | `dot_ansible/roles/zsh` |
| `~/.tmux/plugins/tpm` | `git-repo` | `tmux-plugins/tpm` | `dot_ansible/roles/devtools` |
| `~/.fzf`（僅 Linux） | `git-repo` | `junegunn/fzf` | `dot_ansible/roles/lazyvim_deps` |
| `~/.local/share/toolkami/toolkami.rb` | `file` | `aperoc/toolkami/main/toolkami.rb` | `dot_ansible/roles/ruby_gem_tools` |

所有 `git-repo` 條目皆使用 `--depth 1` 並在 pull 時使用 `--ff-only`；所有條目皆設定 `refreshPeriod = "168h"`（每週自動刷新）。

### 更新如何傳播

```bash
chezmoi apply                 # 一般節奏：檢查 refreshPeriod，
                              # 只在超過 168h 時才從上游 pull
chezmoi apply --refresh-externals   # 強制：立刻 pull 每個 external
```

External 的求值會在 `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` **之前**執行，所以 ansible 啟動時，`~/.oh-my-zsh`、`~/.tmux/plugins/tpm`、`~/.fzf`、`~/.local/share/toolkami/toolkami.rb` 都已經存在。Ansible 對這些工具剩下的職責：

- `zsh` role：安裝 `zsh` 套件 + 變更登入 shell（sudo）。
- `devtools` role：執行 `tpm/bin/install_plugins` 一次（sentinel 為 `~/.tmux/plugins/.ansible-installed`）。
- `lazyvim_deps` role：執行 `~/.fzf/install --bin`（透過 `creates: ~/.fzf/bin/fzf` 達成 idempotent）。

### 巢狀 external

`.oh-my-zsh` 與 `.oh-my-zsh/custom/plugins/<name>` 都各自宣告為獨立的 `git-repo` external。chezmoi 在刷新時是 `git pull`（不是重新 clone），所以子目錄會跨刷新保留下來 —— 這是標準的 oh-my-zsh 安裝模式。

### 何時加進 `.chezmoiexternal`，何時留在 ansible

適合 `.chezmoiexternal`：

- 純 git clone 或單一檔案下載，除了 `.chezmoi.os` 條件外沒有 arch / OS 邏輯。
- clone 後沒有建置步驟（或建置步驟是 idempotent 而且住在 ansible 中）。
- 你希望上游能依排程自動 pull。

留在 ansible：

- 條件式 arch / `noRoot` / `armv7l` 跳過邏輯（GitHub release binary）。
- 目的路徑包含動態版本 (dynamic version) 的 clone（例如 `claude-hud` 在路徑中使用 `v<tag>` 並寫入 `installed_plugins.json`）。
- 任何 clone 後需要 `become: true` 的事情。

### 編輯流程

1. 在 `.chezmoiexternal.toml.tmpl` 中新增 / 移除條目。
2. `chezmoi diff` —— 確認沒有意料外的目標 diff（external 不會顯示逐檔 diff；你會看到 TOML 變動）。
3. `chezmoi apply --refresh-externals` —— 抓取並套用。
4. 如果你移除了一個條目，chezmoi **不會**刪除目的目錄（它已經不再受管理）。如果你想要乾淨狀態，請手動移除。

## 本 repo 中的案例研究

下面是上述 `modify_` / `create_` 模式的三個具體實作說明，附帶我們踩過的失敗模式。

### `dot_claude/modify_settings.json` — 透過 jq 進行部分 JSON 管理

Claude Code 會在執行階段重寫 `~/.claude/settings.json`（新增 `permissions`、`skipAutoPermissionPrompt`、重新排序鍵）。靜態的受管理檔案會在每次 apply 時都產生 diff。

`modify_` 檔案是可執行腳本：chezmoi 把目前目標內容透過 stdin 餵入，並期望從 stdout 拿到新內容。腳本使用 `jq '. * $overlay'` 把受管理覆蓋層深度合併到實際檔案上：

- 覆蓋層中的鍵由 chezmoi 強制：`hooks`、`enabledPlugins`、`extraKnownMarketplaces`、`skipDangerousModePermissionPrompt`、`statusLine`。
- Claude Code 新增的其他任何鍵（model、permissions、`skipAutoPermissionPrompt` 等）會被原封不動保留。
- 覆蓋層中的陣列會整批取代對應陣列，因此 `hooks.Notification` 不會累積重複項。

要管理額外的鍵，把它加到 `dot_claude/modify_settings.json` 中的 `overlay` heredoc。需要 `jq`（由 `base` ansible role 安裝）。來源檔案必須具備 exec bit（git mode `100755`）。

**失敗模式**：如果實際的 `~/.claude/settings.json` 含有無效 JSON（例如 Claude Code 寫入了多餘的尾隨逗號），`jq` 會以 parse error 中止，腳本以非零狀態退出。chezmoi 會記錄 `chezmoi: .claude/settings.json: exit status 5` 並跳過該檔案；損壞的實際檔案保持不動，等待手動檢視。絕不會寫出部分 / 損毀的輸出。修好或刪除實際檔案後再執行 `chezmoi apply`。

### `.chezmoitemplates/editor/*` — VSCode / Cursor / Antigravity 的共用覆蓋層

三個 Electron 編輯器都從各自的 `User/` 目錄讀取 `settings.json` + `keybindings.json`（macOS `~/Library/Application Support/<Editor>/User/`、Linux `~/.config/<Editor>/User/`）。我們要跨編輯器、跨作業系統管理三件事，又不想跟編輯器本身的寫入打架：

1. 一個小小的**通用基線**（Hack Nerd Font Mono、相對行號、format on save、smart accept-suggestion、終端機字型）—— 真理來源在 [`.chezmoitemplates/editor/overlay.json`](../../.chezmoitemplates/editor/overlay.json)。在這裡新增一個鍵，就會部署到全部六個目標（3 個編輯器 × 2 個 OS）。
2. **快捷鍵 (keybindings)**，全新機器要種子化、但永不覆寫編輯器自己加的項目（例如 Cursor 的 `alt+cmd+s`）—— 真理來源在 [`.chezmoitemplates/editor/keybindings.json`](../../.chezmoitemplates/editor/keybindings.json)。
3. `modify_` / `create_` 機制本身 —— bash + python + jq 合併腳本只住在 [`.chezmoitemplates/editor/modify.sh`](../../.chezmoitemplates/editor/modify.sh) 一處；六個 per-editor wrapper 都是一行的 `{{ template … }}` 殼。

`modify_settings.json.tmpl` 在 pipe 進 `jq '. * $overlay'` 之前，使用內嵌的 Python JSONC 規範化器（去掉 `//` 與 `/* */` 註解 + 尾隨逗號）。這是整個 repo 中唯一需要在原處深度合併實際 JSONC 的地方；**請勿複製這個腳本** —— 如果你需要新的覆蓋層段落（例如 `[python]` 區塊覆寫），請擴充 [`modify.sh`](../../.chezmoitemplates/editor/modify.sh)。

`create_keybindings.json.tmpl` 是一次性種子化。要把更新過的基線推給已存在的實際檔案，請把實際檔案複製回來源路徑（`cp ~/Library/Application\ Support/Code/User/keybindings.json "$(chezmoi source-path ...)"`）以納入編輯器新增的條目，再編輯樣板。

**[`.chezmoiignore.tmpl`](../../.chezmoiignore.tmpl) 中的存在性閘門 (presence gating)。** 它在錯誤的 OS 上忽略跨 OS 樹的兩半（非 darwin 上忽略 `Library/**`，非 linux 上忽略 `.config/{Code,Cursor,Antigravity}/**`），接著各編輯器的 `stat` 閘門會在編輯器設定目錄不存在時忽略整個子樹。淨效果：只裝了 VSCode 的全新機器會拿到 Code settings、完全跳過 Cursor / Antigravity，沒有幻影目錄。`Library`、`Application Support` 與各編輯器目錄上的 `private_` 前置詞會保留 macOS 原生的 `0700` / `0755` 模式。

當要新增第四個編輯器時（例如 Zed 若採用相同布局），把它加到 `.chezmoiignore.tmpl` 中的 `range (list "Code" "Cursor" "Antigravity" "NewEditor")` list，並對應建立 4 個來源檔案（`{modify_settings,create_keybindings}.json.tmpl` × macOS / Linux）。

### `dot_config/nvim/create_lazy-lock.json` — 一次性種子化，永不覆寫

LazyVim 在每次 `:Lazy update` 都會重寫 `~/.config/nvim/lazy-lock.json`，且各 OS 的外掛清單不同。`create_` 只在目標檔案尚不存在時寫入（新機器種子化），所以後續編輯不會產生任何 chezmoi diff。

**在刻意更新外掛後刷新基線**。`chezmoi re-add` 與 `chezmoi add` 都不是這裡正確的工具：

- `chezmoi re-add` 會默默**跳過** `create_` 檔案（這是設計如此 —— `create_` 表示內容不受管理）。
- `chezmoi add` 會**剝除** `create_` 前置詞，把它升級為一般受管理檔案（這違背了整個目的）。

正確做法是直接把實際檔案複製到來源路徑（這會保留前置詞）：

```bash
cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"
```

這是一個明確、需自願執行的步驟，而不是每次 apply 都產生噪音。

## 另見

- [docs/this_repo/cheatsheet.md → chezmoi](../this_repo/cheatsheet.md#chezmoi) — 指令層級的快速參考。
- [chezmoi docs — Concepts](https://www.chezmoi.io/reference/concepts/) — source state、destination state、target state 的差異。
- [chezmoi docs — Include files from elsewhere](https://www.chezmoi.io/user-guide/include-files-from-elsewhere/) — `.chezmoiexternal.<format>` 使用者指南。
