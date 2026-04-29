# `bootstrap.sh` — 全新機器的第一觸入口

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

儲存庫的一行式安裝命令：

```bash
curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash
```

只做三件事（腳本本身約 75 行，大部分是日誌）：

1. **若 [`uv`](https://github.com/astral-sh/uv) 不存在則安裝**（Astral 提供的安裝程式 → `~/.local/bin/uv`）。
2. **將 stdin 重新接到 `/dev/tty`**，使 `dotfiles_init.py` 內的 [`questionary`](https://github.com/tmbo/questionary) 提示能讀取按鍵（否則 `curl` pipe 會搶走 stdin，wrapper 將靜默地退回非互動式 stub）。
3. **`exec uv run --script <URL>`** — 透過 HTTPS 抓取 [`scripts/init/dotfiles_init.py`](../../scripts/init/dotfiles_init.py)，把它的 PEP 723 inline 相依套件 (`questionary`、`rich`、`tyro`) 解析到一個臨時 venv，並執行它。沒有全域 `pip install`，沒有 `pyproject.toml`。

`bootstrap.sh` 列在 [`.chezmoiignore.tmpl`](../../.chezmoiignore.tmpl) — `chezmoi apply` **不會**把它部署到 `$HOME/bootstrap.sh`。

## 「已經 5 分鐘沒有輸出——是不是卡住了？」

最有可能是 wrapper 在靜默下載某些東西。三個層級在網路慢或被限速時各自可能花 30 秒～數分鐘，且**完全沒有可見輸出**：

| 層級 | 正在發生什麼 | 如何確認 |
|---|---|---|
| `curl https://astral.sh/uv/install.sh \| sh` | 從 GitHub Releases 下載 `uv` binary 壓縮檔 | `pgrep -af 'uv\|curl\|install.sh'` |
| `uv run --script <URL>`（相依套件階段） | 從 PyPI 解析並下載 `questionary` / `rich` / `tyro` 的 wheel；建置任何 sdist | `lsof -p $(pgrep -f dotfiles_init) -i \| head` |
| `chezmoi init`（提示之後） | 透過 HTTPS / SSH `git clone` dotfiles 儲存庫（含 submodule、agent skill 等，數 MB） | `pgrep -af 'git\|chezmoi'` |

### 不中斷執行的情況下進行診斷

在同一台機器的**另一個 shell** 內：

```bash
# 1) see the full process tree under bootstrap
echo "=== process tree ==="
pgrep -af 'bootstrap|dotfiles_init|uv|chezmoi|ansible|brew|apt|git'

# 2) what is the leaf doing right now?
LEAF=$(pgrep -f 'dotfiles_init|chezmoi|ansible' | tail -1)
[ -n "$LEAF" ] && {
  ps -p "$LEAF" -o pid,ppid,etime,stat,command
  lsof -p "$LEAF" 2>/dev/null -i | head -10        # network sockets
  lsof -p "$LEAF" 2>/dev/null -p "$LEAF" | grep REG | tail -10  # files being read
}

# 3) which remote is slow?
for url in https://astral.sh https://raw.githubusercontent.com \
           https://pypi.org https://github.com https://get.chezmoi.io; do
  printf '%-40s ' "$url"
  curl -fsS --max-time 5 -o /dev/null -w 'HTTP %{http_code}  %{time_total}s\n' "$url" \
    || echo 'TIMEOUT/FAIL'
done
```

常見模式：

- **`curl` 對 `astral.sh` 花費 >30 秒** → GFW；設定 `https_proxy`（見下方）。
- **`uv` 行程 (process) 存在但沒有 TCP socket** → resolver 正在 CPU 密集地建置一個大型 sdist（這三個相依套件很少見；通常代表某個遞移 (transitive) 相依拉了重東西進來）。等它，或以 `DOTFILES_BOOTSTRAP_VERBOSE=1` 重跑。
- **`git-remote-https` / `git-remote-ssh` 子行程** → `chezmoi init` 正在 clone；GFW 慢在這裡是正常的。
- **Python 行程處於 `select()` 且沒有子行程** → 它正在等待鍵盤輸入。TTY 重新接掛失敗；請結束並從真正的終端機重跑（不要透過非 PTY 的 SSH session）。

### Verbose 模式

以全方位的進度輸出重跑：

```bash
curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh \
  | DOTFILES_BOOTSTRAP_VERBOSE=1 bash
```

這會在 `bootstrap.sh` 內設定 `set -x`、印出帶時間戳記的階段日誌，並加上 `uv run --verbose` 讓你看到每個 wheel 下載 / venv 操作。

## 完全跳過 `bootstrap.sh`（在慢速網路上推薦）

當你已經在本機 clone 過儲存庫之後，根本不需要 `curl` pipe 的 bootstrap——直接透過 `just` recipe 呼叫 wrapper script：

```bash
git clone https://github.com/daviddwlee84/dotfiles ~/.local/share/chezmoi
cd ~/.local/share/chezmoi

just bootstrap-local                 # interactive (same as bootstrap.sh)
just bootstrap-local-verbose         # shows uv resolver progress

# Pass through args after `--`:
just bootstrap-local -- --yes --bundle minimal     # non-interactive
just bootstrap-local -- doctor                     # schema parity check
just bootstrap-local -- list-bundles               # see all bundles
```

優點：

- **不需對 wrapper script 做 `raw.githubusercontent.com` 來回**（只剩相依套件還需要 PyPI，而 PyPI 可換鏡像；見下方）。
- **不需要 `/dev/tty` re-exec 體操**——你已經在真正的 shell 裡了。
- **可以 `git pull` 並重跑**以測試 wrapper 的變更，不必再跑 `curl` pipeline。
- **可以 `git checkout <branch>`** 並在合併前執行 feature 分支的 wrapper。

`bootstrap.sh` 唯一比 `just bootstrap-local` 多做的事就是自動安裝 `uv`。如果新主機上沒有 `uv`，先安裝一次：

```bash
curl -fsSL https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

然後執行 `just bootstrap-local`。

## 在 GFW / 公司 proxy 後面

三個層級各需要不同的 proxy / mirror 設定。最便宜的方式是執行一個本機 SOCKS / HTTP proxy（clash、v2ray 等）監聽 `127.0.0.1:7890`：

```bash
# (1) shell layer — curl, git, uv installer
export https_proxy=http://127.0.0.1:7890
export http_proxy=$https_proxy
export all_proxy=socks5://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1

# (2) git layer — chezmoi init clones via git
git config --global http.https://github.com.proxy "$https_proxy"
# (or globally: git config --global http.proxy "$https_proxy")

# (3) uv / PyPI layer — switch index instead of routing through proxy
export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# Tencent / Aliyun mirrors also work:
#   https://mirrors.cloud.tencent.com/pypi/simple
#   https://mirrors.aliyun.com/pypi/simple/
```

如果 `raw.githubusercontent.com` 本身才是瓶頸（bootstrap pipeline 中第一個 `curl`），請指向 mirror：

```bash
# ghproxy.com proxies *.githubusercontent.com transparently
export DOTFILES_RAW_URL="https://ghproxy.com/https://raw.githubusercontent.com/daviddwlee84/dotfiles"
export DOTFILES_REF=main

curl -fsSL "${DOTFILES_RAW_URL}/${DOTFILES_REF}/bootstrap.sh" | bash
```

`bootstrap.sh` 在組成內層 script 的 URL 時會尊重 `DOTFILES_RAW_URL` / `DOTFILES_REF`，因此內層的 `uv run --script` 也會走同一個 mirror。

> **注意 — jsdelivr / cdn.statically.io 風格的 CDN** 使用不同的 URL scheme (`/gh/owner/repo@ref/path`)，不能直接當作 `DOTFILES_RAW_URL`。請使用 `ghproxy.com` 風格的透明 proxy，或乾脆 clone 到本機並使用 `just bootstrap-local`。

## 內層 `dotfiles_init.py` 做了什麼

請參閱 `scripts/init/dotfiles_init.py`（約 836 行）— 它預檢 chezmoi / git / SSH，透過 `questionary` 呈現分組的功能旗標 (feature-flag) 提示，然後呼叫 `chezmoi init <repo> --apply --promptString …`。子命令：

- `init`（預設）— 互動流程。
- `doctor` — 對 `.chezmoi.toml.tmpl` + `Dockerfile` 進行 grep，並驗證每個提示鍵都鏡射到腳本的 `PROMPTS` tuple。對 CI 友善；偏移時以非零碼結束。請參閱 [AGENTS.md → Dockerfile + dotfiles_init wrapper](../../AGENTS.md)。
- `list-bundles` — 顯示預先設計好的功能旗標 bundle (`personal-mac` / `work-mac` / `server-linux` / `minimal`)。

## 相關連結

- [`scripts/init/dotfiles_init.py`](../../scripts/init/dotfiles_init.py) — wrapper。
- [`.chezmoi.toml.tmpl`](../../.chezmoi.toml.tmpl) — chezmoi 看到的提示定義。
- [`Dockerfile`](../../Dockerfile) — 第三個必須保持同步的檔案（CHEZMOI_* build arg）。
- [docs/this_repo/initial_setup/](initial_setup/) — 全新機器安裝的敘事式逐步說明。
- [docs/this_repo/fleet-apply.md](fleet-apply.md) — 一台機器跑起來之後，從那台機器把設定推送到整個 fleet。
