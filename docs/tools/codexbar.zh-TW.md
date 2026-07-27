# CodexBar

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[CodexBar](https://github.com/steipete/CodexBar) 顯示各家 AI 編碼 provider 的用量限額、重設倒數、
點數與本機 token 成本，不必登入每一家的儀表板。截至 v0.45.2 約支援 63 家 provider——Codex、Claude、
Cursor、Gemini、Copilot、OpenRouter、Grok、Bedrock、z.ai、Kimi，以及一長串較新的服務。

- **macOS 14+**：選單列 (menu bar) 應用程式**加上**內建 CLI——cask 會同時裝好兩者
- **Linux**：僅 CLI。桌面面板都是社群專案，全部建構在這支 CLI 之上
  （[Waybar](https://github.com/Marouan-chak/codexbar-waybar)、
  [GNOME](https://extensions.gnome.org/extension/9841/codexbar/)、
  [KDE](https://github.com/tylxr59/KodexBar)、Cinnamon）

## 本 repo 如何安裝

全部集中在
[`dot_ansible/roles/coding_agents/tasks/main.yml`](../../dot_ansible/roles/coding_agents/tasks/main.yml)
的 `# === CodexBar ===` 區塊。

| 平台 | 機制 | 結果 |
|---|---|---|
| **macOS 14+**（Intel **與** Apple Silicon 皆可） | `brew install --cask codexbar`——homebrew-cask **core**，不需要 tap | `/Applications/CodexBar.app` + PATH 上的 `codexbar` |
| **Linux**，glibc ≥ 2.38 且 Linuxbrew 可用 | `brew install steipete/tap/codexbar`（CLI formula） | brew prefix 下的 `codexbar` |
| **Linux**，glibc ≥ 2.38，沒有 Linuxbrew | GitHub release tarball | `~/.local/bin/codexbar` |
| **Linux**，glibc < 2.38 | static-musl 的 GitHub release tarball——刻意繞過 Linuxbrew | `~/.local/bin/codexbar` |

role 的安裝判斷是 `/Applications/CodexBar.app`，**不是** `which codexbar`——原因見下方的
binary 名稱衝突。

### macOS：cask 是 CLI formula 的超集

上游有兩種產物都會提供 `codexbar` 執行檔：

| | `brew install --cask codexbar` | `brew install steipete/tap/codexbar` |
|---|---|---|
| 內容 | `CodexBar.app` **加** CLI（`binary … target: "codexbar"`） | 僅 CLI |
| 選單列 / Settings UI | 有 | 無 |
| 平台 | 僅 macOS 14+ | macOS **與** Linux |

兩者會衝突：都要把同一個 `codexbar` 名稱連結進 brew prefix，因此當 formula 佔著這個名稱時，
Homebrew 會拒絕連結 cask 的 binary。**只能擇一。** 在 macOS 上 cask 是嚴格的超集，所以 role 會先
移除既有的 `codexbar` formula 再安裝 cask（並附帶 rescue：cask 安裝失敗時把 formula 裝回來）。

也正因為這個衝突，在 macOS 上用 `which codexbar` 當安裝判斷是錯的：裝了 CLI formula 的主機會被
判定成「已安裝」，於是永遠拿不到 GUI。

### Intel Mac 已經支援——不要再加回 arm64 gate

| 版本 | 日期 | 變化 |
|---|---|---|
| ≤ v0.25 | — | GUI 僅 arm64；core cask 帶有 `depends_on arch: :arm64` |
| **v0.26.0** | 2026-05-15 | 應用程式改以 `CodexBar-macos-universal-*.zip` 發布；**架構限制取消** |
| v0.17.0 | 2026-02-02 | cask 進入 homebrew-cask **core**——裝 cask 已不再需要 `steipete/tap` |

現在唯一的條件是 `depends_on macos: :sonoma`（macOS 14+）；role 會對更舊的 macOS 印出明確訊息並
跳過，而不是讓 cask 直接讓整個 play 失敗。

### Linux：預編的 glibc CLI 需要**非常新**的發行版

`linux-<arch>` tarball 是在現代 CI 上編出來的 Swift 二進位檔。用 `objdump -p CodexBarCLI` 讀
v0.45.2 自家 asset 的 `.gnu.version_r`，可以看到真正的底線遠高於慣用的 Linuxbrew 分界——
`linux-x86_64` 與 `linux-aarch64` **兩者**都需要：

- 來自 `libc.so.6` 的 `GLIBC_2.38`
- 來自 `libstdc++.so.6` 的 `GLIBCXX_3.4.30`（GCC 12+）

| 發行版 | glibc | 預編 glibc CLI |
|---|---|---|
| Ubuntu 24.04 | 2.39 | 可執行 |
| Ubuntu 22.04 | 2.35 | **失敗** |
| Debian 12 | 2.36 | **失敗** |
| RHEL / Rocky 9 | 2.34 | **失敗** |
| CentOS 7 | 2.17 | **失敗** |

上游自 **v0.37.0**（2026-06-20）起提供的靜態 build 則是空的 `NEEDED` 清單、零 `GLIBC_*` 參照，
到哪都能跑。role 會探測 glibc 再據此挑選：

| 偵測到的 glibc | Asset |
|---|---|
| ≥ 2.38 | `CodexBarCLI-v<tag>-linux-<arch>.tar.gz`（約 43 MB） |
| < 2.38，或無法偵測 | `CodexBarCLI-v<tag>-linux-musl-<arch>.tar.gz`（約 79 MB，靜態） |

!!! danger "這個探測**刻意**連 Linuxbrew 那條路一起 gate 住"
    `steipete/tap/codexbar` 是一個下載二進位檔的 formula，抓的是**同一個 glibc tarball**。
    因此在 Jammy / bookworm / RHEL-9 主機上 `brew install` 會「成功」，卻留下一個根本執行不了的
    binary——而既然安裝判斷是 `which codexbar`，之後每一次執行都會跳過那個真正能用的 musl
    fallback。所以當 glibc < 2.38 時，role 會直接繞過 Linuxbrew，走靜態 tarball。

偵測不到 glibc 時*偏向* musl 是刻意的：靜態版到哪都能跑，代價只是多下載約 36 MB。

!!! warning "不要去接上游的 `.sha256` sidecar"
    每個 release asset 都有 `<asset>.tar.gz.sha256`，但內容是
    `<sha>  /tmp/tmp.XXXXXX/CodexBarCLI-…`——那是**建置機器的絕對暫存路徑**，不是單純的檔名。
    Ansible `get_url` 的 checksum-URL 查找是以檔名比對，永遠對不上，所以下載任務刻意不設
    `checksum:`。

## 沒有 GUI 時的首次設定

provider 開關平常放在應用程式的 **Settings → Providers**。純 CLI 安裝（Linux，或 macOS 尚未裝
cask 時）請改用 `config` 子命令，否則直接執行 `codexbar` 只會回報它能自動偵測到的少數幾家：

```bash
codexbar config providers                  # 列出 id 與啟用狀態
codexbar config enable  --provider claude
codexbar config disable --provider cursor
codexbar config validate                   # 警告仍是 exit 0，錯誤不是
codexbar config dump --pretty

# API-key 類 provider，且不會落進 shell history
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
```

`set-api-key` 會 trim 掉管線傳入的值、以受限權限寫入，並順帶啟用該 provider（用 `--no-enable`
可略過啟用）。

### 設定檔位置

新安裝使用 XDG 路徑；當沒有 XDG 設定檔時，舊路徑仍然有效：

| 路徑 | 狀態 |
|---|---|
| `~/.config/codexbar/config.json` | 目前的預設（支援絕對路徑的 `XDG_CONFIG_HOME`） |
| `~/.codexbar/config.json` | 舊路徑，既有安裝仍會讀取 |
| `$CODEXBAR_CONFIG` | 明確覆寫 |

## 命令

| 命令 | 用途 |
|---|---|
| `codexbar usage` | 即時限額 / 配額。**這是預設命令**——直接打 `codexbar` 就是跑它 |
| `codexbar cost` | 從 Claude/Codex/Cursor 日誌算本機 token 成本。`--days 1…365`、`--group-by project`、`--refresh` |
| `codexbar cards` | 以終端機卡片格線輸出單次快照；`--brief` 改成精簡表格 |
| `codexbar serve` | 前景 HTTP JSON 伺服器（`/health`、`/usage`、`/cost`、`/dashboard/v1/snapshot`） |
| `codexbar guard --provider <id>` | 依剩餘配額 gate 自動化流程；exit code 穩定 |
| `codexbar config …` | providers / enable / disable / set-api-key / validate / dump |
| `codexbar cache clear` | `--cookies`、`--cost`、`--all` |
| `codexbar cookie refresh` | 重新匯入某個 provider 的瀏覽器 cookie |
| `codexbar hooks …` | 列出 / 啟用 / 停用 / 測試外部事件 hook |

### `--source` 語意

`--source <auto|web|cli|oauth|api>`，預設 `auto`，而且 fallback 順序是**每家 provider 各自定義**
（例如 Codex：OpenAI web dashboard → 缺 cookie 時退回 Codex CLI；Claude：claude.ai API → Claude
CLI）。輸出的標頭一定會標示實際採用的策略：`== Claude 2.1.220 (claude) ==`。

在 **Linux** 上，瀏覽器類的 `auto` / `web` 模式不支援——但 `auto` 仍然能解析，會往本機檔案、
provider CLI、OAuth 或已設定的 manual cookie 落下去。所以在 Linux 上**不再需要**強制
`--source cli`；只有在你就是要走 provider CLI 那條路時才用得上。

### `guard` 的 exit code

```bash
codexbar guard --provider codex --min-remaining 20 --window weekly --json
```

| Code | 意義 |
|---|---|
| `0` | 達到或高於門檻（`--fail-open` 也會把「無法判定」轉成這個值） |
| `1` | 低於門檻 |
| `64` | 參數無效 |
| `69` | 配額查不到，或所選的時間窗不存在 |

### `serve` 的安全預設

預設綁 `127.0.0.1:8080`。`/usage` 與 `/cost` **只有**在 loopback 綁定時免驗證；綁到非 loopback
主機時每一條資料路由都需要 `Authorization: Bearer …`，而且啟動還必須額外加 `--allow-plain-http`
（因為 token 會以明文穿越網路）。請優先用 `CODEXBAR_DASHBOARD_TOKEN` 而非 `--dashboard-token`，
後者會從 `ps` 洩漏。

## Shell aliases

定義於 [`dot_config/shell/40_codexbar.sh`](../../dot_config/shell/40_codexbar.sh)
（共用層——zsh 與 bash 都會載入）：

| Alias | 命令 | 說明 |
|-------|---------|-------------|
| `cbu` | `codexbar usage --provider claude` | Claude 用量 |
| `cbc` | `codexbar cost --provider claude` | Claude 本機成本 |
| `cbca` | `codexbar cost` | 所有 provider 的本機成本 |

## 陷阱

- **`--provider all` 會查詢所有已註冊的 provider**，而不只是已啟用的那些——在約 63 家的規模下，
  代表在少數真正有結果的輸出之前，會先噴一整面
  `No available fetch strategy for …` 與缺 cookie 的錯誤。請啟用你實際在用的
  （`codexbar config enable`），然後讓預設的 provider 集合去做事。
- **啟用三家以上 provider 時**，預設查詢範圍仍然只涵蓋已啟用的那些。
- **`cost` 完全離線**——它掃描本機 JSONL session 日誌，不需要驗證。會對外連線的是 `usage`。
- **macOS 上 cookie 類 provider 需要完全磁碟取用權 (Full Disk Access)** 才讀得到 Safari 的
  `Cookies.binarycookies`；否則請改用其他瀏覽器、manual cookie、API key，或 OAuth / CLI 來源。
- **從 cask 裝出來的 `codexbar --version` 不會印版號。** formula 會在 `libexec` 裡把一個 `VERSION`
  檔放在 binary 旁邊，所以它印的是 `CodexBar 0.45.2`；app bundle 的
  `Contents/Helpers/CodexBarCLI` 旁邊沒有這個檔，同一個 flag 只會印出光禿禿的 `CodexBar`。
  不要用它做版本檢查——改用 `brew list --cask --versions codexbar`、app 的 Info.plist
  (`CFBundleShortVersionString`)，或 `serve` 的 `/health` 回應。
- **升級不會自動發生**——依本 repo 的
  [install 與 upgrade 分離原則](../this_repo/upgrades.md)，安裝流程只負責安裝。
  `just upgrade-brew` 會一併帶到 cask 與 formula；Linux 的 tarball fallback 則沒有升級路徑。

*命令介面驗證基準：CodexBar v0.45.2（2026-07）。*
