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
| **Homebrew**（bottles/API + brew.git；**不含** core.git —— 見備註） | `$HOMEBREW_*` 環境變數（`dot_config/shell/00_exports.sh.tmpl` + 2 個 bootstrap 腳本） | **BFSU** `mirrors.bfsu.edu.cn/homebrew-*`（最快，2026-07 benchmark）；用 `brew-mirror {bfsu\|ustc\|aliyun\|tuna}` 即時切換 | [bfsu](https://mirrors.bfsu.edu.cn/help/homebrew-bottles/) / [ustc](https://mirrors.ustc.edu.cn/help/brew.git.html) |
| **Rustup**(dist + self-update) | `RUSTUP_DIST_SERVER` / `RUSTUP_UPDATE_ROOT` 環境變數 | `mirrors.tuna.tsinghua.edu.cn/rustup` | [rustup](https://mirrors.tuna.tsinghua.edu.cn/help/rustup/) |
| **mise** Node.js prebuilt | `MISE_NODE_MIRROR_URL` / `NODE_BUILD_MIRROR_URL` 環境變數 | `mirrors.tuna.tsinghua.edu.cn/nodejs-release/` | [nodejs-release](https://mirrors.tuna.tsinghua.edu.cn/help/nodejs-release/) |
| **Go modules** | `GOPROXY` 環境變數 | `goproxy.cn`（Qiniu；TUNA 沒有 Go proxy） | — |
| **Docker Hub**（Linux 上的 rootless Docker） | `~/.config/docker/daemon.json`，透過 `modify_daemon.json.tmpl` | 只剩 DaoCloud —— 另外四個實測已死（見 [docker-net.md](docker-net.md)） | — |
| **Ubuntu apt**（僅 Docker image） | `Dockerfile` | 華為雲 (Huawei Cloud) | [ubuntu](https://mirrors.tuna.tsinghua.edu.cn/help/ubuntu/) |

## 安全性與信任模型 (Security and trust model)

鏡像 (mirror) 是用一道信任邊界 (trust boundary) 換取速度。決定你到底信任鏡像多少的關鍵只有一個問題：**套件完整性 (integrity) 是不是由「鏡像以外的來源」獨立驗證，還是鏡像連「用來比對的 checksum」也一起提供？**

- **若驗證是獨立的**，惡意或被入侵的鏡像無法在不被發現的情況下竄改 —— 被動過的檔案會對不上一個「不是鏡像給的」checksum。
- **若鏡像同時提供「檔案」與「預期 checksum／index」**（沒有 lockfile 的**全新安裝**就是這種情況），你就是在信任該營運方。這是**所有**鏡像或 proxy 的共通性質 —— 公司內部的 Artifactory 也一樣 —— 不是中國鏡像獨有。

第三方在網路上竄改（MITM，中間人攻擊）是另一條軸線，且已被關閉：**此處每個鏡像都是 HTTPS**（沒有明文 `http://`）。

### 第一級 —— 獨立加密驗證（鏡像無法竄改）

| 生態系 | 為何安全 |
|---|---|
| **Go modules** | `GOPROXY=goproxy.cn` 負責提供 module，但 `GOSUMDB=sum.golang.google.cn`（Google 營運、對已簽章 checksum database 的鏡像）會針對 `go.sum` 獨立驗證每個 module。即使 proxy 是惡意的也會被抓到。這是黃金標準 —— 保持 `GOSUMDB` 設定，絕不要關掉。 |

### 第二級 —— 全新安裝時 checksum 與檔案來自同一個鏡像

對**全新**安裝而言這些鏡像是被信任的；而 **lockfile 會把它們升級成第一級**（對已鎖定的東西而言）。

| 生態系 | 鏡像提供的 checksum 來源 | 你擁有的獨立防護 |
|---|---|---|
| **Cargo** | crates.io index（SHA256） | `Cargo.lock` 能抓到已鎖定依賴被竄改 |
| **npm / Bun** | registry metadata | 已鎖定依賴的 `package-lock.json` `integrity`（sha512） |
| **PyPI**（uv/pip） | `simple` index hashes | `uv.lock` 或 hash-pinned 的 `requirements.txt`（`--require-hashes`） |
| **Homebrew** | 透過 `HOMEBREW_API_DOMAIN` 的 formula JSON（API domain **同時**是 bottle checksum 來源，所以鏡像兩者都控制） | 營運方信譽（BFSU = 大學） |
| **RubyGems / conda / Rustup / mise-node** | index／manifest／`SHASUMS256.txt`，皆來自同一鏡像 | 營運方信譽；conda/gem 的 checksum 可放進 lockfile |

第二級的實際防護 = **營運方信譽 + HTTPS + lockfile**。此處所有營運方皆高信譽（TUNA=清華、USTC=中科大、BFSU=北外、SJTU=上交、ZJU=浙大、NJU=南大 等大學；Alibaba/Tencent/Huawei/Baidu/Qiniu 等大廠雲），蓄意投毒有巨大的法律與名譽代價，且它們都是上游的 bit-for-bit rsync 複本。**安全敏感的東西請用 lockfile 釘住**，信任就降到第一級。

### 第三級 —— 解析／中繼資料信任（最該盯的一項）

- **Docker Hub `registry-mirrors`**：pull-through 鏡像負責解析 `tag→digest`，而 Docker Content Trust **預設關閉**，所以是鏡像決定 `latest` 這類 tag 對映到哪個 image。一旦你**以 digest 拉取**（`repo@sha256:…`）就是內容定址、安全。敏感 image 請以 digest 拉取或啟用 Content Trust。`dockerhub.azk8s.cn` 與 `dockerproxy.com` 已於 2026-07 **移除**：失效／第三方的鏡像域名可能註冊過期並被攻擊者重新註冊成惡意的 pull-through cache。

  清單在 2026-07 又從五條砍到**一條**。其中四條實測不能用 —— `docker.mirrors.ustc.edu.cn` 網域完全沒有 DNS 紀錄、`docker.nju.edu.cn` 在校園網外回 403、`mirror.iscas.ac.cn` 回 502、`mirror.baidubce.com` 從百度雲外連會被 TLS reset。移除它們在「可靠性」之外還獨立地是一個**安全性**改善：**每一條都是一個有權決定 `latest` 解析到哪個 image 的第三方**，而「以防萬一」留長的清單，只是替那些根本用不到它的主機把這個攻擊面放到最大。取代廣度的是 daemon proxy 加上 client 端抓取（`docker-net pull`），這兩者都不會把 digest 解析權交給任何人。要加回任何一條之前先量測：`docker-net mirrors`。

### 殘餘風險（即使用可信鏡像也存在）

- **時效落後 (staleness)** —— 鏡像可能落後上游，延遲安全修補，或短暫供應一個上游已撤回 (yanked) 的版本。
- **全新安裝的信任** —— 沒有 lockfile 的第二級是在信任營運方；被入侵的鏡像伺服器才是現實威脅（而非營運方蓄意作惡）。
- **依賴混淆 (dependency confusion)** —— 只有在你於 `uv.toml` 的公開 PyPI 鏡像旁再加入**私有** index 時才會發生；那裡的 `index-strategy = "unsafe-first-match"` 之所以安全，**僅**因三個 index 都是公開的。見 `dot_config/uv/uv.toml.tmpl` 內的警告。

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

### `brew update` / 任何 `brew` 指令卡住 60 秒以上然後什麼都沒做

`HOMEBREW_BREW_GIT_REMOTE` git 鏡像的 smart-HTTP `upload-pack` 壞掉了：`git ls-remote`（ref advertisement）會成功，所以鏡像**看起來**健康，但實際的 packfile fetch 會卡住。**Aliyun 的 `brew.git` 就有這個 bug** —— 它在 2026-07 之前是預設基準，凍結了每次 `brew update`（以及每次 `brew install` / `brew upgrade` 前的 auto-update），直到 `unset HOMEBREW_BREW_GIT_REMOTE` 才解。

修法：換一個可用的鏡像。Benchmark（2026-07，中國網路 —— `brew.git` shallow fetch + ~30 MB bottle-index 下載）：

| 鏡像 | brew.git fetch | bottle 吞吐 | 結論 |
|---|---|---|---|
| **BFSU** | 1.1s | 31 MB/s | 最快 —— **目前基準** |
| USTC | 1.0s | 11 MB/s | 穩定 fallback |
| Aliyun | **FAIL**（upload-pack） | 17 MB/s | git 壞了，bottles 正常 |
| TUNA | **timeout 45s** | 6 MB/s | 排隊中，兩者都慢 |

用 `brew-mirror {bfsu|ustc|aliyun|tuna}` 即時切換後 `brew update`。基準設在 `dot_config/shell/00_exports.sh.tmpl`（+ 兩個 bootstrap 腳本）。完整除錯過程：`pitfalls/homebrew-aliyun-brew-git-hang-core-clone-bloat.md`。

### `brew` 磁碟用量暴增 / `brew update` 從快變慢

檢查 `du -sh "$(brew --repo homebrew/core)/.git"`。如果是 ~1 GB，表示 homebrew/core 從 API stub（~8 KB）被轉成了完整的 git clone —— 這會在 `HOMEBREW_CORE_GIT_REMOTE` 被**設定**且 `brew update` 執行時發生。Homebrew 4.x 以 JSON API（`HOMEBREW_API_DOMAIN`）為事實來源，所以 `HOMEBREW_CORE_GIT_REMOTE` 應保持**未設定**。恢復精簡的 API 模式：

```bash
brew untap homebrew/core     # 移除 ~1 GB 的 clone；formulae 仍透過 API 解析
unset HOMEBREW_CORE_GIT_REMOTE
```

`brew-mirror` helper 會 unset 它，並自動 untap 殘留的 >100 MB clone。

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
