# pre-commit

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> 一份關於 [pre-commit](https://pre-commit.com/) 的**通用**參考——掛鉤 (hook) 框架本身、它的 Python 環境模型如何運作，以及在系統 Python 損壞時如何讓 `pre-commit` 維持穩健（[`uv`](https://docs.astral.sh/uv/) 小技巧）。本倉庫實際採用的 hook 清單與作用範圍規則，請參閱 [`this_repo/testing.md` § shellcheck + shfmt](../this_repo/testing.md#shellcheck--shfmt)。

## 什麼是 pre-commit

[pre-commit](https://pre-commit.com/) 是一個語言中立 (language-agnostic) 的框架，用於在 git commit 時執行短小的檢查。`.pre-commit-config.yaml` 檔案宣告了一份「hook 倉庫」清單（每個都是包含一個或多個 hook 的 GitHub 倉庫），並以 `rev:` 進行版本鎖定 (versioning)。首次使用時，pre-commit 會把每個倉庫 clone 到 `~/.cache/pre-commit/`，為每個倉庫建立**獨立的 virtualenv / gem / go-module / npm 環境**，並以 `rev:` 為鍵進行快取。

粗略的生命週期 (lifecycle)：

```text
觸發 commit
  → pre-commit run（透過 .git/hooks/pre-commit shim）
  → 對每個 staged 檔案，與每個 hook 的 `files:` 樣式比對
  → 對每個符合的 hook：
      - 確保該 hook 的環境存在於 ~/.cache/pre-commit/repo<hash>/
      - 若不存在，clone repo@rev、建構環境、加入快取
      - 以比對到的檔案路徑呼叫該 hook 的進入點 (entrypoint)
  → 非零退出碼 → commit 中止
```

關鍵的心智模型是：**pre-commit 會用安裝它時所用的 Python 來引導 (bootstrap) 每個 hook 的環境。** Hook 本身可以以任何語言執行（Node、Go、Ruby、Rust、Python），但 `virtualenv`／`installer` 的呼叫是由那個 bootstrap Python 發起的。所以如果**那個** Python 壞掉，整個系統都不會運作。

## 常用指令

```bash
pre-commit install            # 安裝 git hook（.git/hooks/pre-commit）
pre-commit install --install-hooks   # 同時預先建構每個 hook 的環境

pre-commit run                # 對目前 staged 的檔案執行
pre-commit run --all-files    # 對「所有」被追蹤的檔案執行
pre-commit run <hook-id>      # 只執行單一 hook（例如 shellcheck）
pre-commit run <hook-id> --files path/to/file

pre-commit autoupdate         # 將每個 `rev:` 更新到該倉庫的最新 tag
pre-commit autoupdate --repo <url>   # 只更新單一倉庫
pre-commit clean              # 清空 ~/.cache/pre-commit/
pre-commit gc                 # 對不再符合任何設定的快取環境進行 GC

# 暫時繞過（不要養成習慣）：
git commit --no-verify        # 對這次 commit 跳過所有 hook
SKIP=hook-id-1,hook-id-2 git commit   # 跳過特定 hook
```

`autoupdate` 並不會*執行* hook——它只是改寫 `rev:` 的鎖定版號，並提示「記得實際執行一次」。本倉庫把這個動作接入 `just upgrade-plugins`。

## 本倉庫如何安裝 pre-commit（單一事實來源）

本倉庫**在每個作業系統上以相同方式**安裝 `pre-commit`：作為由 uv 管理的工具，並鎖定 (pin) 到 CPython 3.13。

```bash
uv tool install --force pre-commit --python 3.13
```

該指令本身就是單一事實來源 (single source of truth)。它會在三個地方執行，三者都會收斂到 `~/.local/bin/pre-commit`：

| 進入點 | 檔案 | 何時執行 |
|---|---|---|
| Ansible role | [`dot_ansible/roles/security_tools/tasks/main.yml`](../../dot_ansible/roles/security_tools/tasks/main.yml) | `chezmoi apply` → `ansible-playbook macos.yml/linux.yml`，以及 `just ansible-security` |
| Justfile recipe | [`justfile`](../../justfile) `pre-commit-install-tool`（被 `pre-commit-setup` 與 `setup-dev` 依賴） | `just pre-commit-setup`、`just setup-dev` |
| Doctor recipe | [`scripts/pre-commit-doctor.sh`](../../scripts/pre-commit-doctor.sh) 透過 `just pre-commit-doctor` | 依需求執行，當 hook 出問題時 |

`uv` 本身由 [`run_once_before_00_bootstrap.sh.tmpl`](../../run_once_before_00_bootstrap.sh.tmpl) 在任何 ansible role 執行之前就先安裝，所以上面的安裝指令永遠都能取得 `uv`。

`uv tool install --force pre-commit --python 3.13` 實際做的事：

1. 將乾淨的 CPython 3.13 下載到 `~/.local/share/uv/python/`（與 Homebrew 或系統正在做的事彼此隔離）。
2. 在 `~/.local/share/uv/tools/pre-commit/` 底下建立專屬的 venv。
3. 將 `~/.local/bin/pre-commit` 符號連結 (symlink) 到該 venv 的 script。

之後，`pre-commit` 會在**你能控制**的 Python 下執行，獨立於 Homebrew／系統升級。新的 hook 環境會由那個 3.13 來引導，意思是它們也會使用 3.13（除非某個 hook 透過 `language_version:` 覆寫）。

### 為何鎖定 3.13（而非 Homebrew Python）

Homebrew 的 `python@3.14` 過去曾搭載 (bundle) 一份 `libexpat`，其 ABI 與 macOS 系統的 `/usr/lib/libexpat.1.dylib` 不一致，導致 `pre-commit` 為建構 hook 倉庫所發出的每次 `virtualenv` 呼叫都失敗（症狀：載入 `pyexpat` 時 `Symbol not found: _XML_SetAllocTrackerActivationThreshold`）。鎖定 CPython 3.13 可以閃過整類由 brew Python 升級造成的破壞——同時讓 hook 快取鍵 (cache key)（pre-commit 會從 bootstrap Python 版本推導）在不同機器與隊友之間保持穩定。

### PATH 優先順序：`~/.local/bin/pre-commit` 如何勝出

uv 安裝只有在 PATH 中 `~/.local/bin` 排在 brew 的 `/opt/homebrew/bin` 與 conda 的 `~/miniforge3/bin` 之前才有用。本倉庫的 zsh export（[`dot_config/zsh/00_exports.zsh.tmpl:21`](../../dot_config/zsh/00_exports.zsh.tmpl)）會處理這件事：

```sh
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
```

由於這個 export 在 conda 的 lazy init（[`dot_config/zsh/tools/04_conda_mamba.zsh`](../../dot_config/zsh/tools/04_conda_mamba.zsh)）之前執行，所以由 uv 管理的執行檔會勝出。驗證方式：

```bash
which pre-commit        # → ~/.local/bin/pre-commit
which -a pre-commit     # 依 PATH 順序列出所有副本
```

### 被 conda 遮蔽的失敗模式

若你看到 `which pre-commit` 回傳 `~/miniforge3/bin/pre-commit`（或類似結果），那是 conda 把 `pre-commit` 連帶安裝進它的 `base` 環境，而你 PATH 排序把 conda 放到了 `~/.local/bin` 之前。修復選項：

```bash
# 選項 A：直接請出 doctor
just pre-commit-doctor

# 選項 B：移除 conda 的副本
conda remove -n base pre-commit     # 若它被裝進 base
conda deactivate                    # 或是直接離開 base

# 選項 C：解除安裝 brew 的副本（如果遮蔽源是 brew）
brew uninstall pre-commit
```

PATH 遮蔽 (shadow) 通常就是「我跑了 `just setup-dev`，但 `pre-commit --version` 顯示的版本卻不是 ansible role 安裝的那個」的原因。

### 團隊／多機器注意事項

如果團隊共用 `.pre-commit-config.yaml`，但部分隊友使用 Homebrew 安裝的 pre-commit、其他人使用 uv 鎖定版本，則每組會在 `~/.cache/pre-commit/` 之下建構並維護各自獨立的快取。無害，只是稍嫌浪費。快取鍵反正是 per-user，所以沒有跨使用者的失效 (invalidation) 風險——但若想要完全可重現的快取鍵，就讓所有人都跑一次 ansible role 或 `just pre-commit-setup`，這樣大家都會落在同一個 uv 鎖定的 3.13 上。

### 不要與 `uv-*` hook 混淆

[Astral 為 pre-commit 撰寫的 uv 指南](https://docs.astral.sh/uv/guides/integration/pre-commit/) 探討的是另一個層面——在 `.pre-commit-config.yaml` 裡*提供* `uv-*` hook（例如 `uv-lock`、`uv-export`、`pip-compile`）。這跟「是哪一個 Python 在執行 `pre-commit` 本身？」（也就是本節在談的問題）正交。本倉庫目前沒有在 `.pre-commit-config.yaml` 裡使用任何 `uv-*` hook。

## 除錯損壞的 hook 環境

在深入下方各種情境之前，**先試試 doctor**——它能涵蓋 90% 的案例：

```bash
just pre-commit-doctor                 # 診斷 + 透過 uv 自動修復
just pre-commit-doctor --run-hooks     # 同上，外加 hook 環境的 smoke test
./scripts/pre-commit-doctor.sh --check # 只診斷（不重新安裝）
```

Doctor 會檢查 `uv` 是否存在、確認 `pre-commit` 解析到 `~/.local/bin/pre-commit`（而不是被 conda／brew 遮蔽的副本）、掃描已知不良的 `pyexpat`／`virtualenv` 錯誤特徵，並在發現問題時重新執行 `uv tool install --force pre-commit --python 3.13` 加上 `pre-commit clean`。

Pre-commit 錯誤通常落在以下幾類：

### 1. "An unexpected error has occurred: CalledProcessError … virtualenv"

Bootstrap Python 為其中一個 hook 倉庫建構 virtualenv 失敗。常見原因：

- **Python 小版本升級後，`pyexpat`／標準函式庫 (standard library) 共享物件損壞。** 症狀：`ImportError: dlopen(...pyexpat...Symbol not found: _XML_SetAllocTrackerActivationThreshold`。這是 Python 內建 `libexpat` 的 ABI 與系統 `/usr/lib/libexpat.1.dylib` 不一致所致。**修復：** `just pre-commit-doctor`——它會在不受影響的 uv 鎖定版 CPython 3.13 下重新安裝 pre-commit。（手動等價：`uv tool install --force pre-commit --python 3.13 && pre-commit clean`。）
- **系統 `libssl`／`libcrypto` 版本不相容**——同類問題。修復方式相同：透過 doctor 重新鎖定。
- **`~/.cache/pre-commit/` 磁碟空間不足／權限問題**。

### 2. Hook 失敗但你不知道為什麼

```bash
pre-commit run <hook-id> --all-files --verbose
```

Verbose 模式會印出 hook 呼叫的完整指令列以及 stdout／stderr。對於跑在 `-d`（diff）模式的格式化器 (formatter)（`shfmt`、`black --check`），stderr 通常*就是*那段有用的 diff。

### 3. Hook 在 commit 時跑得太慢

```bash
# 預先安裝環境，讓首次 commit 變快：
pre-commit install --install-hooks

# 或是這次 commit 跳過特定的慢 hook：
SKIP=ansible-lint git commit
```

### 4. "files were modified by this hook"

自動格式化器的 hook（trailing-whitespace、end-of-file-fixer、`-w` 模式的 shfmt、black）會**改寫**檔案後以非零退出碼結束，強迫你 `git add` 改寫後的版本並重新 commit。這是刻意設計：hook 無法修改正在建立中的 commit，只能修改工作目錄樹 (working tree)。範式：

```bash
git commit -m "..."
# hook 改寫了檔案，commit 中止
git add -A
git commit -m "..."
# 這次通過
```

如果你希望格式化器只做檢查（這樣 CI 可以失敗而不改寫），多數工具都支援 `-d`／`--check`／`--diff`。本倉庫就是基於這個原因執行 `shfmt -d`。

### 5. 一切無效時就重置

```bash
pre-commit clean              # 清空快取環境，下次 commit 強制重新引導
pre-commit uninstall          # 移除 git hook
pre-commit install --install-hooks    # 重新安裝 + 預先建構
```

## 值得知道的整合點

- **倉庫根目錄的 `.pre-commit-config.yaml`** —— hook 清單與 `rev:` 鎖定版本。
- **hook 提供者倉庫中的 `.pre-commit-hooks.yaml`** —— 一個倉庫如何對外暴露 hook。（在撰寫本地 `repo: local` hook 或自訂的共用倉庫時很有用。）
- **`language: system`** —— 跳出 virtualenv 沙盒，直接從 PATH 執行 shell 指令。本倉庫對 `./scripts/redact_secrets.py --fix` 使用此模式，這樣 hook 就不會嘗試自行配置 Python。
- **`language: python` + `additional_dependencies:`** —— 在 hook 的 venv 裡額外安裝 pip 依賴 (dependency)。Hook 快取會以這個清單作為鍵，因此新增依賴會使快取失效並觸發重建。
- **`files:`／`exclude:` 正規表達式 (regex)** —— 通常你唯一需要動的效能調節旋鈕。積極地把 `files:` 範圍縮小；對所有檔案都跑的 hook 很快就會變慢。
- **`stages:`** —— hook 可以對 `pre-commit`、`pre-push`、`commit-msg`、`post-checkout` 等階段觸發。預設只在 `commit` 階段。

## 另見

- [pre-commit.com](https://pre-commit.com/) —— 上游官方文件。
- [Using uv with pre-commit](https://docs.astral.sh/uv/guides/integration/pre-commit/) —— 由 `uv` 管理的 hook。
- [`docs/this_repo/testing.md` § shellcheck + shfmt](../this_repo/testing.md#shellcheck--shfmt) —— *本*倉庫如何使用 pre-commit（hook 清單、範圍、zsh 例外）。
- [`docs/this_repo/cheatsheet.md` § Pre-commit & Gitleaks](../this_repo/cheatsheet.md#pre-commit--gitleaks) —— 指令快速參考。
