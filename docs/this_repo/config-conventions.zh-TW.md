# 設定檔慣例 (Config file conventions)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本文快速導覽本 repo 採用的 dotfile／設定檔組織模式 (organisation patterns)、
各自存在的原因，以及新檔案應放置的位置。

這是一份**慣例參考文件 (conventions reference)**，並非 chezmoi 教學——
chezmoi 的機制請見 [`tools/chezmoi-templating.md`](../tools/chezmoi-templating.md)
與 [`tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md)；shell 專屬的
分層規則請見 [`shells/architecture.md`](../shells/architecture.md)。

---

## A. 設定檔放在哪裡 (Where configs live)

### A1. XDG Base Directory Specification

[freedesktop.org spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)；
現代的預設方案。四個環境變數 (env vars) 將 `$HOME` 切分成依用途標記的子樹：

| Env var             | 預設值                  | 內容用途 |
| ------------------- | ---------------------- | -------- |
| `$XDG_CONFIG_HOME`  | `~/.config/`           | 使用者設定（90% 的現代工具放這裡） |
| `$XDG_DATA_HOME`    | `~/.local/share/`      | 應用資料、工具安裝（mise toolchains、oh-my-zsh、blesh、…） |
| `$XDG_CACHE_HOME`   | `~/.cache/`            | 可丟棄的快取 (caches)（zsh history search cache、bat cache、…） |
| `$XDG_STATE_HOME`   | `~/.local/state/`      | 執行期狀態 (runtime state)；重要性低於 data，較少使用 |
| `$XDG_RUNTIME_DIR`  | `/run/user/$UID/`      | 揮發性、亞秒級範圍的 IPC sockets（僅 Linux） |

遵循 XDG 的工具（多數現代工具）：nvim、git、mise、starship、
zoxide、direnv、bat、eza、atuin、zellij、gh、fd、ripgrep。

**不**遵循 XDG 的工具（為向後相容卡住）：
- bash (`~/.bashrc`、`~/.bash_profile`)
- zsh (`~/.zshrc`——但支援 `ZDOTDIR` 重導)
- ssh (`~/.ssh/`)
- 一些較舊的工具 (`~/.tmux.conf`、`~/.gemrc`、`~/.npmrc`、`~/.curlrc`)

在本 repo 中：`dot_config/{nvim,git,mise,starship,zoxide,direnv,bat,
eza,atuin,zellij,gh,fd,ripgrep,zsh,bash,shell}/`——XDG 位置。

### A2. 工具專屬目錄 (Tool-specific dirs, pre-XDG)

OpenSSH 位於 `~/.ssh/`，並要求嚴格的 0700 權限。Bash 堅持使用 `$HOME`
下的 `~/.bashrc` / `~/.bash_profile`。tmux 預設為 `~/.tmux.conf`
（較新版本也接受 `~/.config/tmux/tmux.conf`）。我們順從各工具實際的查找
順序，而非與之對抗。

在本 repo 中：`dot_ssh/`、`dot_bashrc.tmpl`、`dot_zshrc.tmpl`、
`dot_gitconfig.tmpl`（同樣放在 `$HOME`——git 2.13+ 也讀取
`~/.config/git/config`，但 `~/.gitconfig` 是經典的標準位置）。

### A3. 平台專屬目錄 (Platform-specific dirs)

部分工具即便不採 XDG，也會使用 OS 原生目錄：

| OS       | 慣例                                          |
| -------- | --------------------------------------------- |
| macOS    | `~/Library/Application Support/<App>/`        |
| Windows  | `%APPDATA%\<App>\`                            |
| Linux    | 通常為 XDG；偶爾為 `~/.<app>/`                 |

在本 repo 中：`Library/Application Support/{Code,Cursor,Antigravity}/`
（僅 macOS 的 chezmoi 模板；在 `.chezmoiignore.tmpl` 中按 OS 條件 gating，
避免在另一個 OS 上產生幽靈目錄 (phantom dirs)）。

---

## B. 模組化設定的組織方式 (How modular config is structured)

### B1. 單一標準檔 (Single canonical file)

最簡單的模式：一個 rc 檔搞定一切。
範例：`~/.gitconfig`、`~/.tmux.conf`。

優點：可從上而下閱讀，不會有載入順序的意外。
缺點：超過 ~500 行後變得難以管理；多個來源同時貢獻時會發生 merge conflict。

### B2. `.d/` drop-in 片段 (drop-in fragments)

源自 `/etc/` 的舊式 sysadmin 模式 (`/etc/cron.d/`、`/etc/sudoers.d/`、
`/etc/profile.d/`、`/etc/apt/sources.list.d/`)。一個標準檔加上一個 `.d/`
目錄；工具會掃描該目錄並依字母順序載入每個片段 (fragment)。

使用者端範例：
- `~/.ssh/config.d/*`（OpenSSH 7.3+；由 `~/.ssh/config` 中的
  `Include config.d/*` 指令拉入）
- `~/.bashrc.d/*`（RHEL/Rocky/Alma/Fedora skel；其 `~/.bashrc` 會迴圈載入此目錄）
- `~/.bash_completion.d/*`（較不標準；某些補全框架使用）

優點：丟一個檔進去就啟用。每個片段獨立；套件可不修改標準設定就附帶一份。
缺點：順序受 glob 排序左右、易脆 (fragile)（多數採用 `NN_` 前綴）。
原生不支援 `.d/` 的工具需要手寫 loader。

在本 repo 中：`dot_ssh/private_config.d/` → `~/.ssh/config.d/*`，
由 `~/.ssh/config` include 進來。此外 `~/.bashrc.d/*` 在
`dot_bashrc.tmpl` 第 11 步以使用者向後相容層 (user backward-compat layer)
被 source（**並非**我們放置 chezmoi 管理之 bash 設定的位置——見 B3）。

### B3. 混合式：XDG 位置 + `.d` 風格模組化 (Hybrid: XDG location + `.d`-style modular inside)

當工具的標準設定檔原生不支援 `.d/`，但我們又想取得模組化的好處時：
把模組化檔案放在 XDG 位置，並自行寫一個 loader。

在本 repo 中：`dot_config/{shell,zsh,bash}/NN_*.{sh,zsh,bash}`——
由 `dot_zshrc.tmpl` / `dot_bashrc.tmpl` 中定義的 `load_modular_dir` 函式
glob `*.<ext>` 並依字母順序 source。`NN_` 檔名前綴控制載入順序。

為什麼不直接放在 `~/.bashrc.d/`？因為（在 RHEL 上）skel 的
`~/.bashrc.d` 迴圈是從原本的 `~/.bashrc` 內部執行的——當我們將其替換
為自管的 bashrc 後，那個迴圈就不存在了。我們自己的 bashrc 在第 11 步
（在 ble-attach 之後）才 source `~/.bashrc.d/*`，這對 OMB plugin
設定或 pre-init env 來說太晚。所以受管的設定放在
`~/.config/{shell,bash}/`（在 bashrc 中段被載入），而 `~/.bashrc.d/`
保留給**使用者自行放入**的檔案。

完整深入說明：[`shells/architecture.md`](../shells/architecture.md)。

### B4. 套件管理器目錄 (Plugin manager directories)

當工具有套件管理器 (plugin manager)（oh-my-zsh、oh-my-bash、tpm、lazy.nvim、
direnvrc）時，套件存在框架管理的專屬目錄中：

- `~/.oh-my-zsh/custom/plugins/<plugin>/`（OMZ；透過
  `.chezmoiexternal.toml.tmpl` clone）
- `~/.oh-my-bash/custom/plugins/<plugin>/`（OMB；同樣模式）
- `~/.tmux/plugins/<plugin>/`（TPM）
- `~/.config/nvim/lazy-lock.json` + `~/.local/share/nvim/lazy/<plugin>/`
  (lazy.nvim——設定在 XDG_CONFIG_HOME，payload 在 XDG_DATA_HOME)

我們不去抗拒它們——讓框架自己管自己的目錄，並透過
`.chezmoiexternal.toml.tmpl` clone 上游套件，讓 chezmoi 每週自動拉取。

---

## C. 使用者自訂層 (User customisation layers, override patterns)

這些是逃生口 (escape hatches)——讓使用者藏放本機專屬或實驗性設定的位置，
而不污染 chezmoi 管理的檔案。

### C1. `~/.foorc.local` include（[include] 指令模式）

適用於標準設定支援「include 另一個檔案」指令的情況。受管檔案
結尾條件性 include `~/.foorc.local`；該本機檔案被 gitignored / chezmoi-ignored。

本 repo 範例：
- `dot_gitconfig.tmpl` include `~/.gitconfig.local`（per-machine
  `[safe]`、`[credential]`、`[http.proxy]`）。列在
  `.chezmoiignore.tmpl` 中，所以 chezmoi 不會追蹤它。檔案不存在時
  會無聲略過（git 的 `[include] path = ~/.gitconfig.local` 是寬容的）。
- `dot_ssh/dot_config` 以類似方式 include `~/.ssh/config.local`。

何時使用：當工具具備原生 include 指令，且標準設定有穩定的結構、
不會因部分覆寫而壞掉時。

### C2. `~/.foorc.adhoc` 自我載入尾段（本 repo chezmoi-ignored 模式）

當沒有原生 include 指令時——我們在受管 rc 檔的尾端手動實作一個：

```bash
# end of dot_zshrc.tmpl / dot_bashrc.tmpl
[ -r "$HOME/.zshrc.adhoc" ] && . "$HOME/.zshrc.adhoc"
```

第一次 apply 時自動建立，並附上標頭註解。列在 `.chezmoiignore.tmpl` 中。
最後 source，因此遇到衝突時使用者永遠勝出。

何時使用：希望提供 per-machine 覆寫但又不想強迫使用者學習 chezmoi 模板的
shell rc 檔。標準範例見 `dot_zshrc.tmpl` 與 `dot_bashrc.tmpl`。

### C3. 發行版 skel 慣例（`~/.bash_aliases`、`~/.bashrc.d/*`）

發行版 `/etc/skel/` 設定告訴使用者去填的檔案／目錄。並非 chezmoi 管理；
我們只是 source 它們以保持向後相容，讓既有的使用者內容能在我們接管 rc
之後仍然存活。

範例：
- `~/.bash_aliases`——Debian / Ubuntu skel 會 source 這個；我們受管的
  bashrc 在第 11 步也會 source。
- `~/.bashrc.d/*`——RHEL / Rocky / Alma / Fedora skel 會迴圈載入；
  我們受管的 bashrc 第 11 步也會迴圈載入。
- `~/.profile` / `~/.bash_profile`——login shell 入口；我們的
  `dot_bash_profile.tmpl` 會檢查 `~/.profile` 並在 `~/.bashrc` 之前
  source 它（並透過 `grep` 防止 double-sourcing）。

何時使用：僅用於**使用者端**的 legacy 相容性。我們 chezmoi 管理的設定
**不**放在這裡。

### C4. 機密檔 (Secrets files, gitignored / chezmoi-ignored)

Per-machine 的 API keys、tokens、proxy URLs——絕不追蹤。由受管 rc source，
並做存在性檢查 (presence-gated)：

```bash
[ -r "$HOME/.config/zsh/secrets.zsh" ] && . "$HOME/.config/zsh/secrets.zsh"
```

列在 `.chezmoiignore.tmpl` 中。我們也透過 `create_99_local_proxy.zsh`
提供 baseline-seed 模式（chezmoi 建立一次後，永不再動內容）。

何時使用：任何包含憑證的內容。若「gitignored」還不夠強，chezmoi 文件中的
[`secrets`](https://www.chezmoi.io/user-guide/encryption/age/) 主題涵蓋了
加密替代方案。

---

## D. chezmoi 專屬慣例（檔名前綴與 meta 檔）(Chezmoi-specific conventions)

完整機制請見 [`tools/chezmoi-templating.md`](../tools/chezmoi-templating.md)
與 [`tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md)。TL;DR：

| 前綴 / 後綴          | 行為                                                         |
| ------------------- | ----------------------------------------------------------- |
| `dot_X`             | 部署為 `~/.X`                                                |
| `private_X`         | 以 mode 0600 部署                                            |
| `executable_X`      | 以 mode 0755 部署（或設定 +x bit）                            |
| `*.tmpl`            | 模板化；apply 時渲染                                         |
| `modify_X`          | 一支腳本，從 stdin 接收當前 target，並把新內容寫到 stdout（jq overlay 等） |
| `create_X`          | 種子一次；建立後 chezmoi 永不再動內容                          |
| `run_once_before_*` | 一次性的 pre-apply 腳本                                      |
| `run_onchange_after_*` | 當 inline 依賴的 hash 變動時重新執行                       |

| Meta 檔                            | 用途                                          |
| --------------------------------- | --------------------------------------------- |
| `.chezmoi.toml.tmpl`              | 使用者設定（提示 → data 值）                   |
| `.chezmoiignore.tmpl`             | 要略過 / 按 OS 條件 gating 的來源檔            |
| `.chezmoiremove`                  | apply 時要從 `$HOME` 刪除的路徑（用於遷移）    |
| `.chezmoiexternal.toml.tmpl`      | 上游來源（git clone、檔案下載）                |
| `.chezmoidata*`                   | 注入到所有模板的靜態資料                       |
| `.chezmoiscripts/`                | 不會以檔案形式部署的 run-scripts               |

---

## E. 其他值得知道的相關慣例 (Other related conventions worth knowing)

### E1. PATH 目錄慣例 (PATH directory conventions)

| 目錄                  | 慣例       | 內容 |
| --------------------- | ---------- | ---- |
| `~/bin/`              | 老式 POSIX | 使用者撰寫的 shell 腳本（`dot_bin/` 中有幾個） |
| `~/.local/bin/`       | XDG-ish    | 自動安裝的 CLI（uv、mise、chezmoi、just、fd、eza、…） |
| `~/.cargo/bin/`       | Rust       | cargo 安裝的 binary |
| `~/go/bin/`           | Go         | `go install` 的 target |
| `~/.bun/bin/`         | Bun        | bun runtime + 全域安裝的 JS CLI |
| `~/Library/pnpm/`     | macOS pnpm | pnpm 全域 store |
| `/opt/homebrew/bin/`  | macOS brew | Apple Silicon brew |
| `/usr/local/bin/`     | macOS brew | Intel brew 與舊式 `/usr/local` |

我們在 `dot_config/shell/00_exports.sh.tmpl` 中的順序是刻意的：
較晚 prepend 者勝出，因此 `$HOME/bin` 與 `$HOME/.local/bin` 最終排在最前面。

### E2. Lock 檔 (Lock files)

Lock 檔釘住傳遞性依賴 (transitive dep) 的版本。有些由 chezmoi 管理，
有些被 gitignored，有些是 seed-once：

| 檔案                                       | 模式                  | 原因 |
| ----------------------------------------- | -------------------- | --- |
| `uv.lock`                                 | 追蹤                 | 可重現的 Python 工具安裝 |
| `.chezmoi.toml`                           | gitignored           | `chezmoi init` 的輸出，machine-local |
| `~/.config/nvim/lazy-lock.json`           | `create_`（種子一次） | 首次 apply 後 chezmoi 永不再動 |
| `~/.agents/.skill-lock.json`              | `modify_`（jq 合併）  | chezmoi 管理且可合併 |

模式選擇取決於該檔案應該跨機器完全相同、部分相同，或完全 machine-local。

### E3. Login、interactive、non-interactive shell 載入差異

Bash 與 zsh 區分三種 shell 模式；每種讀取不同的檔案：

| 模式                  | Bash 讀取                                     | zsh 讀取                            |
| --------------------- | -------------------------------------------- | ---------------------------------- |
| Login（TTY/SSH 登入） | `/etc/profile`，然後 `~/.bash_profile`/`~/.bash_login`/`~/.profile` 中第一個存在者 | `/etc/zprofile`、`~/.zprofile`、`/etc/zlogin`、`~/.zlogin`（以及永遠讀取的 `.zshenv`） |
| Interactive non-login | `/etc/bash.bashrc`、`~/.bashrc`              | `~/.zshenv`、`~/.zshrc`             |
| Non-interactive（腳本） | 不讀任何檔（除非設定 `BASH_ENV`）           | 僅 `~/.zshenv`                     |

含意：**腳本需要使用的環境變數**必須放在 `~/.zshenv`（zsh）或透過
`~/.profile`（bash login chain）export——不是 `~/.zshrc` / `~/.bashrc`
（僅 interactive）。

在本 repo 中：多數環境變數放在 `dot_config/shell/00_exports.sh.tmpl`，
從 `~/.bashrc` 與 `~/.zshrc` 兩邊都被 source——僅限 interactive shell。
真正需要 non-interactive scope 的東西（`cron` 的 PATH、
`ssh user@host cmd`）應該放在 `~/.profile` / `~/.zshenv`。我們接受
這個取捨，因為：(a) 多數 non-interactive 腳本會自行設定 PATH；(b)
cron 腳本本來就應該為了可重現性而 hardcode 工具路徑。

### E4. 檔名前綴排序 (Filename-prefix ordering)

當 `.d/` 風格或 hybrid loader 依字母順序排列檔案時，檔名前綴即編碼了
載入順序：

```
dot_config/shell/
├── 00_exports.sh.tmpl     ← 最先執行  (env / PATH)
├── 01_starship.sh         ← prompt 初始化（在 env 之後）
├── 02_legacy_tools.sh     ← legacy PATH 增補
├── 05_mise.sh             ← runtime manager
├── 10_aliases.sh          ← aliases（在 env 之後）
├── 10_fzf.sh
├── 20_zoxide.sh
├── 27_thefuck.sh
└── 30_direnv.sh           ← 最後執行
```

慣例：`00–09` 為 env / PATH；`10–19` 為 prompt 與依賴 env 的工具；
`20–29` 為導航／實用工具；`30+` 為晚期 hook（direnv、OSC 133 等）。
編號之間留間隔以利日後插入——優先用 `15_`，而非硬塞在 `10_` 與 `11_` 之間。

### E5. 模板中的 per-OS / per-profile 條件控制 (Per-OS / per-profile gating in templates)

當同一份來源在不同 OS 或 profile 下需要不同行為時，有兩種模式：

1. **chezmoi 模板 `if`**（在模板渲染時）：
   ```go
   {{ if eq .chezmoi.os "darwin" -}}
       eval "$(/opt/homebrew/bin/brew shellenv)"
   {{ else -}}
       # Linuxbrew path
   {{ end -}}
   ```

2. **執行時偵測 (runtime detection)**（在 source 時）：
   ```bash
   if [ -n "$ZSH_VERSION" ]; then
       eval "$(starship init zsh)"
   elif [ -n "$BASH_VERSION" ]; then
       eval "$(starship init bash)"
   fi
   ```

何時使用：若差異很大（整段條件式設定區塊）或值在 apply 時即固定，採用
chezmoi 模板。若同一份檔案需在不同 shell（我們的 shared 層）或不同
runtime 條件（某 binary 是否存在）下都要能跑，採用 runtime detection。

不要 double-gate：若 chezmoi 模板的 `if` 已排除某 branch，該 branch 內
的 runtime 檢查就是死碼 (dead code)。擇一即可。

---

## F. 交叉參考 (Cross-references)

- [`tools/chezmoi-templating.md`](../tools/chezmoi-templating.md)——
  chezmoi 模板語言、OS 偵測、何時用模板 vs 靜態檔。
- [`tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md)——
  `dot_`、`private_`、`executable_`、`modify_`、`create_` 前綴語意的
  完整列表與案例研究。
- [`shells/architecture.md`](../shells/architecture.md)——三層 shell
  配置 (`dot_config/shell/` vs `dot_config/zsh/` vs
  `dot_config/bash/`)、遷移歷程 (migration story)、未來 shell 擴充。
- [`shells/aliases.md`](../shells/aliases.md)——以來源檔為 key 的
  alias / function 清單。
- [`tools/agent-overlays.md`](../tools/agent-overlays.md)——`modify_`
  前綴用於 jq-based 設定 overlay 的案例研究。
- [`CLAUDE.md`](../../CLAUDE.md)——agent-facing 維護契約；跨檔規則
  （`README.md`、`mkdocs.yml`、`docs/`、`docs/shells/aliases.md` 的
  更新義務）。
