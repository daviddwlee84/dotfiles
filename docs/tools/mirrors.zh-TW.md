# GFW / 中國鏡像 (mirror) — `useChineseMirror`

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

單一個 chezmoi 提示（`useChineseMirror`，於 `chezmoi init` 時回答）就會驅動本 repo 觸及的每個套件生態系的鏡像設定。啟用時，鏡像會在下次 `chezmoi apply` 自動接好 —— 不需要手動編輯環境變數。

大多數鏡像指向 [TUNA（清華大學開源軟體鏡像站）](https://mirrors.tuna.tsinghua.edu.cn/)，少數例外則指向另一個事實上的標準鏡像（npm → npmmirror、Docker Hub → DaoCloud、Go modules → goproxy.cn、Ubuntu apt → 華為雲 (Huawei Cloud)）。

## 快速切換

```bash
# 檢視目前的值
chezmoi data | rg useChineseMirror

# 翻轉旗標（重新跑 init 提示）
chezmoi init --force        # 會重新詢問 useChineseMirror

# 或直接編輯 ~/.config/chezmoi/chezmoi.toml：
#   useChineseMirror = true / false
# 然後：
chezmoi apply
```

## 涵蓋矩陣

| 生態系 | 由什麼管理 | 鏡像 | TUNA 文件 |
|---|---|---|---|
| **PyPI**（`uv` / `pip`） | `~/.config/uv/uv.toml` | Aliyun → TUNA → USTC（多 index fallback） | [pypi](https://mirrors.tuna.tsinghua.edu.cn/help/pypi/) |
| **npm** | `~/.npmrc` | `registry.npmmirror.com` | — |
| **Bun** | `~/.config/.bunfig.toml` | `registry.npmmirror.com` | — |
| **crates.io**（Cargo） | `~/.cargo/config.toml` | TUNA sparse index | [crates.io-index](https://mirrors.tuna.tsinghua.edu.cn/help/crates.io-index/) |
| **RubyGems** | `~/.gemrc` | `mirrors.tuna.tsinghua.edu.cn/rubygems/` | [rubygems](https://mirrors.tuna.tsinghua.edu.cn/help/rubygems/) |
| **Anaconda / Mamba** | `~/.condarc` | `mirrors.tuna.tsinghua.edu.cn/anaconda/{pkgs,cloud}` | [anaconda](https://mirrors.tuna.tsinghua.edu.cn/help/anaconda/) |
| **Homebrew**（bottles + brew.git + core.git） | `$HOMEBREW_*` 環境變數（`~/.config/zsh/00_exports.zsh` + 2 個 bootstrap 腳本） | `mirrors.tuna.tsinghua.edu.cn/homebrew-*` | [homebrew](https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/) |
| **Rustup**(dist + self-update) | `RUSTUP_DIST_SERVER` / `RUSTUP_UPDATE_ROOT` 環境變數 | `mirrors.tuna.tsinghua.edu.cn/rustup` | [rustup](https://mirrors.tuna.tsinghua.edu.cn/help/rustup/) |
| **mise** Node.js prebuilt | `MISE_NODE_MIRROR_URL` / `NODE_BUILD_MIRROR_URL` 環境變數 | `mirrors.tuna.tsinghua.edu.cn/nodejs-release/` | [nodejs-release](https://mirrors.tuna.tsinghua.edu.cn/help/nodejs-release/) |
| **Go modules** | `GOPROXY` 環境變數 | `goproxy.cn`（Qiniu；TUNA 沒有 Go proxy） | — |
| **Codex CLI transport** | `~/.codex/config.toml`，透過 `modify_config.toml.tmpl` | 不是鏡像；縮短 OpenAI WebSocket retry（`1`、`3000ms`）後更快進入 HTTPS fallback | — |
| **Docker Hub**（Linux 上的 rootless Docker） | `~/.config/docker/daemon.json`，透過 `modify_daemon.json.tmpl` | DaoCloud / USTC / NJU / ISCAS / Baidu / azk8s（fallback chain） | — |
| **Ubuntu apt**（僅 Docker image） | `Dockerfile` | 華為雲 (Huawei Cloud) | [ubuntu](https://mirrors.tuna.tsinghua.edu.cn/help/ubuntu/) |

## 環境變數匯出於何處（三層）

由環境變數驅動的鏡像（Homebrew、Rustup、mise、Go）會在三個地方匯出，這樣每條程式碼路徑都能拿到鏡像：

| 層 | 檔案 | 為何如此 |
|---|---|---|
| 互動式 shell | `dot_config/zsh/00_exports.zsh.tmpl` | 從終端機執行 `brew install`、`rustup install`、`mise install`、`go install` |
| 首次 bootstrap | `run_once_before_00_bootstrap.sh.tmpl` | 安裝 Homebrew 本身、第一次 `brew install` + 第一次 `uv` / `ansible` 設定（`.zshrc` 還不存在時） |
| Ansible 重跑 | `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` | `community.general.homebrew`、`mise install` 等在 ansible 子行程中 —— 無論呼叫 `chezmoi apply` 的是哪個 shell |

## 哪些**沒有**自動套用鏡像（以及為何）

- **真實 Linux 主機上的系統 `apt`** —— 修改 `/etc/apt/sources.list.d/` 需要 sudo，且使用者通常會在 OS 安裝期間預先設定 apt。只有 Docker image 會把 apt 設成華為雲（見 `Dockerfile`）。
- **`git clone` of github.com** —— 全域 `git insteadOf` 改寫會破壞 gh CLI 與私有 repo；過於侵入。
- **GitHub Releases / `raw.githubusercontent.com`** —— TUNA 有 `github-release`，但對映並不完整；跨 ansible role 改寫 release URL 會很脆弱。
- **pre-commit hook / oh-my-zsh / TPM** —— 這些都從 github.com clone；同樣有上面的改寫疑慮。
- **系統 `pip`** —— `uv.toml` 已經涵蓋主要路徑；系統 pip 只在 `security_tools` role 裡作為 fallback 觸發。

## 從 GitHub Releases 下載的 npm postinstall 腳本

npm registry 已被鏡像 (`registry.npmmirror.com`)，但**有少數 npm 套件會跑 `postinstall` 腳本，直接從 GitHub Releases 下載預編譯二進位檔** —— 完全繞過 npm tarball 鏡像。從中國連 `release-assets.githubusercontent.com`（Azure blob CDN）經常很慢或無法連上，而這些腳本通常**沒有環境變數**可覆寫下載 URL。

症狀：`npm install -g <pkg>` 在印出 `Downloading https://github.com/.../releases/download/...` 後就卡住，沒有後續輸出。npm tarball 下載本身是成功的（從 npmmirror 拉、很快）—— 只有 postinstall 步驟卡住。

| 套件 | postinstall 下載什麼 | 本 repo 的 workaround |
|---|---|---|
| `tree-sitter-cli` | `tree-sitter-{platform}-{arch}.gz` | `dot_ansible/roles/lazyvim_deps/tasks/main.yml` 用 `timeout 180` 包住 → cargo fallback（crates.io 已被 TUNA 鏡像） |
| `node-gyp`（傳遞依賴，建置原生模組時） | platform headers / pre-builts | 沒有受管理的安裝 —— 只有當下游套件需要原生建置時才會觸發 |

當新增一個會跑 `npm install -g <pkg>` 的 ansible task 時：

1. **檢查該套件是否有 postinstall 二進位檔下載** —— `npm view <pkg> scripts.postinstall` 或閱讀其 `install.js`。
2. 如果有，**用 `timeout 180` 包住**並提供合理的 fallback（cargo、apt、從鏡像主機手動下載二進位檔）。
3. **不要單用 `set ignore_errors: true`** —— 它抓不到卡住，只抓得到失敗。請改用 `failed_when: false` + 在 fallback task 上明確的 `treesitter_npm.rc | default(1) != 0` 閘門，讓 `timeout` 退出碼 124 能正確觸發下一步。

## 新增鏡像

1. 確認生態系（由環境變數還是設定檔驅動？）。
2. **環境變數驅動**：在三層全部加上（`00_exports.zsh.tmpl` + `run_once_before_00_bootstrap.sh.tmpl` + `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`），都包在 `{{ if .useChineseMirror -}} ... {{ end -}}` 區塊內。
3. **設定檔驅動**：在 `dot_<tool>/<config>.tmpl` 下用 `{{ if .useChineseMirror }} ... {{ else }} ... {{ end }}` 樣板化設定檔。如果該檔案永遠管理都沒問題（例如 `uv.toml`、`.cargo/config.toml`），就不需要 ignore 閘門。如果它會與使用者管理的檔案衝突（例如 `.condarc`、`.gemrc`），也要在 `.chezmoiignore.tmpl` 中加上閘門：

   ```go-template
   {{- if not .useChineseMirror }}
   .condarc
   .gemrc
   {{- end }}
   ```

4. 更新本檔案的涵蓋矩陣，並在 `README.md` 的「Managed config files」段落加上一行條目。
5. 用 `chezmoi execute-template --init --promptBool useChineseMirror=true < <template>` 與 `chezmoi diff` 測試。

## 疑難排解

### brew install 過程中出現 `curl: (18) Transferred a partial file`

見 [infrastructure-as-code.md → Troubleshooting](./infrastructure-as-code.md#troubleshooting)。

### Conda / Mamba：切換 `useChineseMirror` 後 channel 刷新很慢或失敗

Conda 會快取 channel metadata。強制刷新：

```bash
conda clean -i    # 讓 index cache 失效
mamba clean -i    # mamba 同理
```

### 啟用 `useChineseMirror=true` 後 Rust toolchain 仍然很慢

Rustup 是在 process 啟動時讀取環境變數。如果你啟用了旗標，但已經有開著的 zsh session，舊值仍然在那匯出著。請開新 shell 或執行 `source ~/.zshrc && source ~/.config/zsh/00_exports.zsh`。驗證：

```bash
echo $RUSTUP_DIST_SERVER   # 應該為 https://mirrors.tuna.tsinghua.edu.cn/rustup
```

### Go modules 沒有走 goproxy.cn

跟 Rustup 一樣 —— 重新 source。同時請檢查 `GOPROXY` 是否被 `go env -w GOPROXY=...` 覆寫（這會持久化到 `~/.config/go/env`，且優先於環境變數）。要取消持久化的值：

```bash
go env -u GOPROXY
```

## 相關

- [TUNA 鏡像站](https://mirrors.tuna.tsinghua.edu.cn/) — TUNA 託管的完整清單
- [TUNA Homebrew 指南](https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/)
- [TUNA rustup 指南](https://mirrors.tuna.tsinghua.edu.cn/help/rustup/)
- [TUNA anaconda 指南](https://mirrors.tuna.tsinghua.edu.cn/help/anaconda/)
- [TUNA rubygems 指南](https://mirrors.tuna.tsinghua.edu.cn/help/rubygems/)
- [goproxy.cn](https://goproxy.cn/) — Qiniu 託管的 Go module proxy
- [npmmirror](https://npmmirror.com/) — Alibaba 託管的 npm 鏡像
