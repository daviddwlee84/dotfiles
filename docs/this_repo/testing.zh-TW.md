# Shell 腳本測試

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

這個 repo 如何測試 shell 程式碼、shell 測試工具的全景、以及何時該選哪一種。

---

## 本 repo 的 TL;DR

| 工具 | 角色 | 範圍 |
|------|------|-------|
| [**bats-core**](https://github.com/bats-core/bats-core) | 行為 / 單元測試 (unit test) | `tests/unit/`、`tests/smoke/` |
| [**shellcheck**](https://www.shellcheck.net/) | 靜態分析 (static analysis)（bug、不良引號 (quoting)） | `scripts/*.sh` + `scripts/lib/*.sh` 上的 pre-commit |
| [**shfmt**](https://github.com/mvdan/sh) | 格式化工具 (formatter)（一致性檢查） | `scripts/*.sh` 上的 pre-commit（不含 `scripts/lib/` —— 見 [Shell 日誌輸出](shell-logging.zh-TW.md)） |

用 `just check-all` 跑全部。只跑快速的 unit 套件用 `just bats`。下方[「本 repo 如何組織測試」](#how-this-repo-structures-tests)有說明 `tests/` 目錄樹。

**刻意 _不_ 在範圍內的事：** ansible role 測試、bootstrap / `run_once` 測試、chezmoi 模板 (template) 展開測試、Python 腳本測試、GitHub Actions CI。覆蓋率 (coverage) 刻意收窄 — 這是個人 dotfiles repo，不是函式庫 (library)。

---

## 三個 shell 測試框架

大多數人會在 Bats、ZUnit、ShellSpec 之間挑選。何時用哪個的精簡版本：

### Bats (Bash Automated Testing System) — 本 repo 採用的

一個 Bash 測試框架。測試放在 `*.bats` 檔案中；每個測試是一個 `@test "name" { ... }` 區塊。提供 `run`、`$status`、`$output`、`setup`、`teardown`，加上給 CI 用的 TAP / JUnit 輸出。

選 Bats 的時機：

- 你主要寫 Bash。
- 你要透過**黑箱 (black-box)** 行為測試 CLI 腳本或 zsh 腳本（執行命令、檢查退出碼 + stdout/stderr）。
- 你想要最熱門 / 文件最齊全的 shell 測試生態。

不適合的時機：

- 你要在函式 (function) 層級測試 zsh 特有的函式（plugin、autoload、`${(P)var}`、參數展開 (parameter expansion) 旗標）— Bats 對 zsh 沒有任何親和性。
- 你需要 mocking、覆蓋率或 BDD 文法。

伴隨函式庫（選用，**未在此 vendored** 以維持低儀式感）：

- [`bats-assert`](https://github.com/bats-core/bats-assert) — `assert_equal`、`assert_output --partial` 等。
- [`bats-file`](https://github.com/bats-core/bats-file) — 檔案系統斷言 (assertion)。
- [`bats-support`](https://github.com/bats-core/bats-support) — 上述兩者的共用輔助函式。

### ZUnit — zsh 原生

一個 [ZSH 測試框架](https://github.com/zunit-zsh/zunit)。Testcase 語法類似 Bats 但是用 zsh 寫，所以 zsh 特有的構造在測試與被測試的程式碼中都能自然運作。

選 ZUnit 的時機：

- 你在寫 zsh plugin、autoload 函式，或 zsh 比重高的函式庫。
- 你希望測試 harness 本身*就是* zsh，而不是用 bash 去驅動 zsh。

權衡：生態比 Bats 小，需要 [Revolver](https://github.com/molovo/revolver) 作為相依套件。本 repo 未安裝。

### ShellSpec — 功能完整、跨 shell

[ShellSpec](https://github.com/shellspec/shellspec) 是一個 BDD 框架，可在 dash、bash、ksh、zsh 與 POSIX shell 上執行。支援 mocking、參數化測試、平行執行、覆蓋率。

選 ShellSpec 的時機：

- 你在發布必須跨多個 shell 工作的 shell 函式庫。
- 你想要 RSpec 風格的 `Describe` / `It` / `When` / `The output should …` 語法。
- 你需要 mock 或覆蓋率報告。

權衡：學習成本比 Bats 高；對單純 CLI 行為檢查來說太重。

### 如何決定

| 情境 | 選擇 |
|-----------|------|
| Bash CLI 腳本，測試短而簡單 | **Bats** |
| 你想在函式層級測試的 zsh plugin / autoload 比重高的程式碼 | ZUnit |
| 跨 shell 函式庫，或需要 mock / 覆蓋率 / BDD | ShellSpec |
| 透過外部行為測試的 zsh CLI 腳本 | **Bats**（用 bash 驅動 zsh，對輸出做斷言） |

本 repo 屬於最後一行 — 這裡大多數的「zsh」程式碼其實是「以 CLI 方式被呼叫的 zsh 腳本」，所以即使被測試的程式碼是 zsh，Bats 仍是最簡單的選擇。

---

## 本 repo 如何組織測試

```
tests/
├── test_helper.bash          # shared helpers, sourced by every .bats file
├── unit/
│   ├── zsh_proxy.bats        # proxy helpers in 50_networking.zsh
│   ├── ghget.bats            # GitHub tree-URL parsing in 41_github.zsh
│   └── lan_scan.bats         # pure helpers in lan-scan.sh
└── smoke/
    └── docker_install.bats   # runs inside Docker after full install
```

### `tests/test_helper.bash`

小型輔助函式庫（< 40 行）。提供：

- `$REPO_ROOT` — 指向 chezmoi 原始碼 (source) 的絕對路徑。
- `setup_path_stub` — 建立暫存目錄 (temp dir) 並前置進 `PATH`。透過 `$BATS_STUB_DIR`（不是 stdout）對外暴露路徑，這樣 export 才會延續 — **不要把它包在 `$(...)` 裡**。命令替換 (command substitution) 會在子 shell (subshell) 中執行輔助函式，導致 `export PATH` 遺失。
- `cleanup_path_stubs` — 移除測試期間註冊的所有 stub 目錄。
- 預設的 `teardown()` 會呼叫 `cleanup_path_stubs`。如果某個測試檔自訂了 `teardown()`，記得在最後呼叫 `cleanup_path_stubs` 以保留清理動作。

### `tests/unit/zsh_proxy.bats`

操練 `dot_config/zsh/tools/50_networking.zsh` 中的 proxy 輔助函式：

- `$LOCAL_PROXY_URL` 優先於探測 (probe)。
- 活躍的 Clash 設定 (`mixed-port:` 或 `port:`/`socks-port:`) 優先於通用的 loopback 探測。
- 連接埠 (port) 探測順序：`7890 → 7891 → 1087 → 8118 → 8080`。
- 沒有任何回應時 `_ZSH_NET_PROXY_CACHE=none`。
- `__zsh_net_all_proxy_url` 在 `$LOCAL_PROXY_SOCKS_URL` 有設定時回傳該值；否則退回 HTTP 快取 (cache)。
- `proxy-on` 會 export 全部六個環境變數 (env var) (`http_proxy`、`https_proxy`、`HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`all_proxy`)。
- 拆分 HTTP / SOCKS 配線的迴歸 (regression) 防護 (commit `fa4c063`)。
- `proxy-off` 清掉全部六個再加上 `NO_PROXY` / `no_proxy`，並丟棄已快取的偵測狀態。
- `proxy-status` 退出碼：不可用時為 `1`、可用時為 `0`。

關鍵技巧：每個測試都執行 `zsh -f -c '...'`（不載入啟動檔），讓檔案內的快取 (`$_ZSH_NET_PROXY_CACHE`) 無法在測試之間洩漏，並透過放在 `PATH` 上的暫存目錄 stub 掉 `nc` — 沒有真實網路流量。

### `tests/unit/ghget.bats`

固定住 `dot_config/zsh/tools/41_github.zsh` 中 `ghget` 的 URL 解析行為：

- 對缺失 / 非 GitHub / `/blob/`（檔案，不是樹）URL 拒絕並退出 1。
- 對合法 URL 檢查 `owner`、`repo`、`branch` 與子目錄路徑都完整地抵達 `curl` + `tar` 呼叫。查詢字串 (query string) 與結尾斜線會被剝除。
- 在碰網路前拒絕覆寫已存在的目的目錄。

關鍵技巧：用 bash 腳本 stub 掉 `curl` 與 `tar`，把它們的引數 (args) 記錄到 `$CAPTURE_LOG`。`tar` stub 也會偽造預期解出的目錄（讀 `-C` 目標與最後一個位置引數），讓 `ghget` 中解壓後的 `mv` 能成功 — 沒有真實網路、沒有真實 tarball。

### `tests/unit/lan_scan.bats`

固定住 `dot_config/television/executable_lan-scan.sh` 中的純函式輔助函式：

- `is_usable_ip` — 接受正常的主機 IP；拒絕 link-local (`169.254/16`)、multicast (`224–239/4`)、廣播 (broadcast)、網路位址 (network address)，以及主機 octet 中的 `.0` / `.255`。
- `vendor_for_mac` — 將冒號 / 連字號 / 無分隔的 MAC 格式正規化 (normalise)，並在 nmap 風格的 OUI 資料庫中查找 6 位 hex 前綴。

關鍵技巧：腳本在載入時就會做 dispatch（第 325 行起），所以裸 `source` 會跑 `all` 子命令並嘗試探測網路。繞法是用 `clean` 作為第一個位置引數、針對隔離的 `$XDG_CACHE_HOME` 做 source — `clean` 在隔離的快取目錄下無害，函式定義在之後仍在 scope 中。

### `tests/smoke/docker_install.bats`

在 Dockerfile 建出的測試映像中、`chezmoi apply` + ansible 跑完之後執行。對安裝後狀態做斷言：

- `chezmoi apply` 是冪等 (idempotent) 的（重新 apply 會產生空的 `chezmoi diff`）。
- `zsh -n` 在 `~/.zshrc`、`~/.zshenv`、以及每個 `~/.config/zsh/**/*.zsh` 上通過。
- `nvim --headless "+lua print('ok')" +qa` 退出 0。
- `PATH` 上的核心 CLI 工具：`nvim rg fd fzf zsh just bats`。
- oh-my-zsh plugin 存在 (`zsh-autosuggestions`、`zsh-syntax-highlighting`、`zsh-completions`)。
- Unit 測試在容器的 zsh 下通過（攔截「在我 Mac 上沒事」的迴歸）。

由 `just docker-test` → `docker compose run --build --rm test` → `bats /tmp/dotfiles-source/tests/smoke` 執行。

---

## 執行測試

```bash
# Fast feedback loop (no Docker, no network, sub-second)
just bats

# Smoke tests inside a clean Ubuntu container (slow — builds image)
just docker-test

# Everything: ansible syntax + pre-commit + bats + docker-test
just check-all
```

---

## 值得重複使用的模式

### 從 bats 測試 zsh 程式碼

Bats 是 bash 為基底的，因此把 zsh 當作子 process 驅動。用 `zsh -f -c 'source FILE; <call>'` 跳過啟動檔（隔離被測試程式碼），並透過 `run` 或 `$(...)` 擷取輸出：

```bash
@test "my zsh function does X" {
  result="$(zsh -f -c "
    source '$REPO_ROOT/dot_config/zsh/tools/my_file.zsh'
    my_function arg1 arg2
  ")"
  [ "$result" = "expected" ]
}
```

### Stub 外部命令

在 `PATH` 前置一個包含假二進位檔的暫存目錄：

```bash
@test "probe order regression" {
  setup_path_stub   # populates $BATS_STUB_DIR, updates $PATH

  cat > "$BATS_STUB_DIR/nc" <<'EOF'
#!/usr/bin/env bash
port=""
while [ $# -gt 0 ]; do port="$1"; shift; done
[ "$port" = "$EXPECT_PORT" ] && exit 0 || exit 1
EOF
  chmod +x "$BATS_STUB_DIR/nc"

  EXPECT_PORT=1087 zsh -f -c "source '$REPO_ROOT/.../file.zsh'; my_probe"
}
```

Bats 會在自己的 subshell 中執行每個 `@test` 區塊，所以 `PATH` 修改不會跨測試洩漏。`cleanup_path_stubs`（預設 `teardown`）會移除暫存目錄。

### 從 bash 對 zsh 變數做斷言

在 `zsh -f -c '...'` 內，用 zsh 的間接展開 (`${(P)v}`) 印出由另一個變數命名的變數：

```bash
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
  printf '%s=%s\n' "$v" "${(P)v}"
done
```

接著 bats 對 `$output` 做斷言：

```bash
[[ "$output" == *"http_proxy=http://test:1234"* ]]
```

---

## shellcheck + shfmt

[shellcheck](https://www.shellcheck.net/) 是 shell 腳本的靜態分析工具。[shfmt](https://github.com/mvdan/sh) 是 formatter / format-check 工具。本 repo 兩者都透過 pre-commit 執行。關於通用的 pre-commit 機制（快取位置、`uv` 管理的 bootstrap Python、除錯壞掉的 hook 環境），請見 [`docs/tools/pre-commit.md`](../tools/pre-commit.md)。

Pre-commit hook 來源（見 `.pre-commit-config.yaml`）：

- [`shellcheck-py`](https://github.com/shellcheck-py/shellcheck-py) — 提供可由 Python 安裝的 shellcheck wheel，所以 pre-commit 環境不需要系統範圍的 `shellcheck` 二進位檔。
- [`pre-commit-shfmt`](https://github.com/scop/pre-commit-shfmt) — 圍繞 `shfmt` 的 pre-commit 包裝 (wrapper)，不需要 Go 工具鏈 (toolchain)。

### 其他設定檔語法檢查

除了 shell 工具，`.pre-commit-config.yaml` 也會執行這些 [pre-commit/pre-commit-hooks](https://github.com/pre-commit/pre-commit-hooks) 驗證器 (validator)：

- `check-yaml` — ansible playbook、role 定義、docker-compose、pre-commit 自身。
- `check-toml` — TV cable channel 設定、starship、yazi、alacritty 等。`.tmpl` 檔案被排除，因為 chezmoi 的 `{{ ... }}` go-template token 在渲染前不是合法的 TOML。
- `check-json` — VS Code 設定、claude 設定、lazyvim lockfile 等。
- `check-merge-conflict`、`check-added-large-files`、`detect-private-key`、`end-of-file-fixer`、`trailing-whitespace`。

Ansible **playbook 語法**是透過 `just ansible-syntax-check` / `just lint` 檢查，不是 pre-commit — 在每次 commit 都跑完整 playbook 解析對 pre-commit 熱路徑來說太慢。在推送會動到 ansible 的變更前手動跑 `just lint`。

Hook 範圍（見 `.pre-commit-config.yaml`）：**僅 `^scripts/[^/]+\.sh$`**。這排除了：

- `dot_config/zsh/**/*.zsh` — zsh 特有的語法 (`(( ... ))` 數學、`${(P)v}` 展開旗標、`print -u2`、`emulate -L zsh`、`zmodload`) 會絆倒 shellcheck 的 bash 解析器並產生太多假陽性 (false positive)。
- `*.sh.tmpl` — chezmoi go-template token (`{{ if eq .profile "macos" }}`) 在 shellcheck 看來像不平衡的大括號。
- `scripts/adhoc/*.sh` — 慣例上是實驗性 / 一次性腳本。

如果之後某個 zsh 檔案需要靜態分析，最佳選項是：

- 用 `# shellcheck shell=bash` 跑 shellcheck，然後手動消音已知的假陽性 — 繁瑣。
- 切換到一個能識別 zsh 的 linter（並沒有被廣泛採用的）。
- 或乾脆寫一個 Bats 測試覆蓋你關心的行為。

快速命令：

```bash
# Run only shellcheck on all files
pre-commit run shellcheck --all-files

# Run only shfmt
pre-commit run shfmt --all-files

# shfmt is in diff mode (-d) — to actually rewrite files, install shfmt
# locally and run:
shfmt -i 2 -ci -bn -w scripts/*.sh
```

---

## 新增測試

1. 決定 unit 還是 smoke：
   - 純邏輯、輸入可被 stub → `tests/unit/`。
   - 對安裝後系統狀態的斷言 → `tests/smoke/`。
2. 建立 `tests/unit/<thing>.bats`（或 smoke/）。從這個開始：
   ```bash
   #!/usr/bin/env bats
   load "../test_helper.bash"

   @test "brief description" {
     run some-command
     [ "$status" -eq 0 ]
   }
   ```
3. 執行 `just bats`（或 `just docker-test`）驗證。
4. 如果測試需要 stub，使用 `setup_path_stub` + `$BATS_STUB_DIR`。

判斷一個測試是否值得寫的拇指法則：**這裡發生靜默迴歸 (silent regression) 會讓我花超過十分鐘診斷嗎？** 如果不會，就跳過測試。個人 dotfiles 不需要 80% 覆蓋率。

---

## 測試 TUI 與互動式程式

上面的框架是給以 CLI 方式驅動的 **shell** 程式碼用的。它們不適合**全螢幕 TUI** — Bats 可以黑箱 (black-box) 一個行導向 (line-oriented) 命令（執行它、檢查退出碼 + stdout），但無法渲染終端機的畫面格點 (screen grid)、跟隨游標移動、或可靠地驅動 alternate-screen 應用程式。

這個 repo 只有**一個**真正的全螢幕 TUI：**`mlf`**（`scripts/mlf/tui.py`，一個 Python [Textual](https://textual.textualize.io/) 應用程式）。其他號稱「互動式」的都是行 CLI、`questionary` / `getpass` 提示精靈 (prompt wizard)（`dotcfg`、router CLI）、`y/N` 迴圈 (`pqsum --clean`)，或把選單委派給 Television (`fleet hosts`、`yth` → `tv …`)。

**決策 (2026-07) — 已定方向，尚未實作：**

| 對象 | 工具 | 原因 |
|---|---|---|
| `mlf` Textual 應用程式（我們自己的） | Textual [`Pilot`](https://textual.textualize.io/guide/testing/) + [`pytest-textual-snapshot`](https://github.com/Textualize/pytest-textual-snapshot) | 官方第一方、headless / in-process（無 PTY、無 daemon）、可決定性 (deterministic)；`async with app.run_test() as pilot` + `snap_compare()` SVG 迴歸 (regression) |
| 任意第三方 TUI 二進位檔 | [`pexpect`](https://pexpect.readthedocs.io/) + [`pyte`](https://github.com/selectel/pyte) | 無聊但穩定的 PTY 驅動器 + 畫面格點渲染器；每個較新的「terminal Playwright」都是包這同一套 |

已否決：[`shell-use`](https://github.com/microsoft/shell-use)（Microsoft 的「Playwright for the terminal」）— 功能確實強（鍵鼠、per-cell 顏色、snapshot expect、SVG），但仍是 pre-1.0 beta、README 自承 CLI/安裝不穩定、且跑背景 daemon，與本 repo 的低變動 (low-churn) 原則衝突。repo 內已有先例：`agent-warmup` 透過 detached tmux `send-keys` session 驅動互動式 `claude` TUI。

狀態：**greenfield** — 目前還沒有 repo 範圍的 `pytest` / dev-deps 群組或測試 CI job（唯一的 pytest 套件在 `agent-history-hygiene` skill 裡），因此延後。完整評估、選項表與實作草圖：[`backlog/tui-testing-harness.md`](../../backlog/tui-testing-harness.md)。

---

## 參考資料

- [bats-core docs](https://bats-core.readthedocs.io/) · [bats-assert](https://github.com/bats-core/bats-assert) · [bats-file](https://github.com/bats-core/bats-file) · [bats-support](https://github.com/bats-core/bats-support)
- [ZUnit repo](https://github.com/zunit-zsh/zunit)（需要 [Revolver](https://github.com/molovo/revolver)）
- [ShellSpec docs](https://shellspec.info/) · [ShellSpec repo](https://github.com/shellspec/shellspec)
- [shellcheck wiki](https://www.shellcheck.net/wiki/) · pre-commit hook：[shellcheck-py](https://github.com/shellcheck-py/shellcheck-py)
- [shfmt flags](https://github.com/mvdan/sh/blob/master/cmd/shfmt/shfmt.1.scd) · pre-commit hook：[pre-commit-shfmt](https://github.com/scop/pre-commit-shfmt)
- 本 repo 中的安裝位置：`dot_ansible/roles/devtools/tasks/main.yml`（bats-core 是跨平台；預設不安裝伴隨函式庫）。
