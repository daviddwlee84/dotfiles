# Linux 工具鏈基線 — glibc、libstdc++、kernel、gcc，以及什麼能跑在什麼上面

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

當二進位拒絕執行並出現如 `GLIBC_2.27 not found`、`GLIBCXX_3.4.21 not
found`、`CXXABI_1.3.9 not found` 或 `kernel too old` 等錯誤時，本頁就是
你會翻閱的參考資料。它將**系統端的版本**（glibc、libstdc++、kernel、
libc++）對應到**搭載這些版本的發行版（distro）版本**，並說明哪些組合
真的能跑現代預編譯軟體（Node 18+、numpy 2.x、Bun、Rust 二進位、dotnet）。

這是**與發行版無關的 Linux 知識**——適用於任何你 SSH 進去的 Linux
主機，不只是被 chezmoi 管理的那些。它存在於這個 repo 是因為我們在
老舊的 IDC 伺服器（CentOS 7）上一直撞到同一面牆，且有幾個 pitfalls
交叉連結到這裡。

## 決定什麼能跑的四個數字

當 Linux 二進位載入時，有四個版本很重要，大致依下列重要性排序：

| 層級 | 它控制什麼 | 如何檢查 |
|-------|------------------|--------------|
| **glibc** | 大多數系統呼叫包裝、動態連結器 (dynamic linker)、執行緒、locale | `ldd --version` |
| **libstdc++** | C++ 執行期 (runtime) — 類別佈局、`noexcept`、`std::filesystem` 等 | `strings $(gcc --print-file-name=libstdc++.so.6) \| grep GLIBCXX` |
| **kernel** | 系統呼叫介面、namespaces、io_uring、BPF | `uname -r` |
| **gcc** | 你能*建置*什麼（與 libstdc++ 對應但獨立存在） | `gcc --version` |

每一項都有一個**地板 (floor)**，決定了你能*跑*什麼。天花板則是發行版
允許你安裝的版本（apt/yum 升級是受限的）。在單一機器上，通常無法在
不換 OS 的情況下提高地板。

## 發行版 ↔ 基線對照表 (x86_64)

| 發行版版本 | EOL | glibc | libstdc++ (gcc) | kernel | 預設 Python |
|----------------|-----|-------|-----------------|--------|----------------|
| **CentOS 6** / RHEL 6 | 2020-11 | 2.12 | gcc 4.4 | 2.6.32 | 2.6 |
| **CentOS 7** / RHEL 7 | **2024-06** | **2.17** | **gcc 4.8.5 → libstdc++ 4.8.2** | 3.10.0 | 2.7 / 3.6.8 (EPEL) |
| Ubuntu 18.04 | 2023-05 | 2.27 | gcc 7.5 → libstdc++ 7 | 4.15 / 5.4 (HWE) | 3.6 |
| Debian 10 | 2024-06 | 2.28 | gcc 8.3 → libstdc++ 8 | 4.19 | 3.7 |
| **RHEL 8 / Rocky 8 / Alma 8** | 2029-05 | 2.28 | gcc 8.5 (default) / 11+ (DTS) | 4.18 | 3.6 (default) / 3.9+ (modules) |
| Ubuntu 20.04 | 2025-04 | 2.31 | gcc 9.4 → libstdc++ 9 | 5.4 / 5.15 (HWE) | 3.8 |
| Debian 11 | 2026-08 | 2.31 | gcc 10.2 | 5.10 | 3.9 |
| Ubuntu 22.04 | 2027-04 | 2.35 | gcc 11.4 → libstdc++ 11 | 5.15 / 6.5 (HWE) | 3.10 |
| **RHEL 9 / Rocky 9 / Alma 9** | 2032-05 | 2.34 | gcc 11.4 (default) / newer (DTS) | 5.14 | 3.9 |
| Debian 12 | 2028-06 | 2.36 | gcc 12.2 | 6.1 | 3.11 |
| Ubuntu 24.04 | 2029-04 | 2.39 | gcc 13.2 → libstdc++ 13 | 6.8 | 3.12 |

**兩個重大分水嶺：**

- **glibc 2.17** → **glibc 2.28**：發布於 2012 → 2018。在 CentOS/RHEL
  從 7 升到 8、且大多數發行版約在 2018-2020 升級時跨越。**大多數現代
  預編譯二進位的地板就畫在這裡。**
- **glibc 2.28** → **glibc 2.34/2.35**：發布於 2018 → 2021。在
  RHEL 9 / Ubuntu 22.04 跨越。某些 2025+ 的二進位（特別是靜態連結的
  Rust nightly、某些 Node 版本）的地板畫在這裡。

## 現代軟體實際的需求

這些門檻來自上游發行的成品——它們會隨時間改變，所以請務必到你需要
版本的 release notes 再次確認。

### Node.js（來自 nodejs.org/dist/ 的二進位 tarball）

| Node 版本 | 最低 glibc | EL7 (glibc 2.17) | EL8 (glibc 2.28) | EL9 (glibc 2.34) |
|--------------|-----------|-------------------|-------------------|-------------------|
| 16.x (EOL 2023-09) | 2.17 | ✅ | ✅ | ✅ |
| 17.x (EOL 2022-06) | 2.17 | ✅ | ✅ | ✅ |
| **18.x** (LTS until 2025-04) | **2.28** | ❌ | ✅ | ✅ |
| 20.x (LTS until 2026-04) | 2.28 | ❌ | ✅ | ✅ |
| 22.x (LTS until 2027-04) | 2.28 | ❌ | ✅ | ✅ |
| 24.x (current) | 2.28 | ❌ | ✅ | ✅ |

**EL7 的逃生口**：NodeSource 仍然為 EL7 發布 Node 16 的 RPM（最後一個
與 EL7 相容的 LTS）。該套件是專門針對 glibc 2.17 + libstdc++ 4.8 編譯，
並用內附的執行期作為變通。

```bash
# EL7 only — Node 16 (deprecated upstream but the only option that runs)
curl -fsSL https://rpm.nodesource.com/setup_16.x | sudo bash -
sudo yum install -y nodejs   # node 16.20.x, npm 8.x
```

EOL 警告是真的——沒有安全性修補——但 Node 16 仍可用來安裝靜態二進位
的 CLI（Copilot CLI、Codex CLI、Gemini CLI），這些只需要 npm 來釋放
它們自己內附的執行期。對於長時間運行的生產 Node 伺服器，請離開 EL7。

### Python wheels（manylinux 基線）

| Manylinux tag | 最低 glibc | wheels 通常鎖定的時機 |
|---------------|-----------|-------------------------------|
| `manylinux2014` / `_2_17` | 2.17 | Numpy 1.x、scipy 1.x、pandas 1.x、pyarrow ≤ 13 |
| `manylinux_2_28` | 2.28 | **Numpy 2.x、pandas 3.x、pyarrow 14+、現代資料科學 wheels** |
| `manylinux_2_34` | 2.34 | 少數最新的科學運算 wheels（PyTorch nightly 等） |

**EL7 的影響**：當 uv / pip 在 Python 3.13 上解析套件時，它會優先選擇
最新的 wheel。如果只有 `_2_28` wheels 存在，uv 會回退到**從原始碼建置**，
這需要 gcc ≥ 9（numpy meson 明確 assert 這一點）。EL7 的 gcc 4.8.5 會
失敗。見 [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md)。

### libstdc++ / GCC C++ ABI

發行版隨附的 libstdc++ 是用其系統 gcc 編譯出來的版本。`GLIBCXX_*`
符號版本（3.4.20、3.4.21、3.4.22、…）特別嚴格，因為**新增一個符號就
會 bump 版本，即使 ABI 在技術上是向後相容的**：

| GLIBCXX 符號 | 最低 gcc 釋出 | 常見消費者 |
|----------------|---------------------|------------------|
| `GLIBCXX_3.4.20` | gcc 4.9 | greenlet (Python sqlalchemy)、某些 Node 原生模組 |
| `GLIBCXX_3.4.21` | gcc 5.1 | Node 18+、dotnet 6+、libwebkit |
| `GLIBCXX_3.4.22` | gcc 6.1 | dotnet 7+ |
| `GLIBCXX_3.4.26` | gcc 9 | 較新的 std::filesystem 功能 |
| `CXXABI_1.3.9` | gcc 5 | 大多數現代 C++ 二進位 |

**EL7 上的 libstdc++ 來自 gcc 4.8.5**——所以 `GLIBCXX_3.4.20` 與
`CXXABI_1.3.9` 都不存在。這會踩到：

- Bun（musl 變體繞過 glibc，但連結器在某些建置中仍引用新 CXXABI）
- .NET / dotnet（需要 GLIBCXX_3.4.20+）
- 原生 Python C++ 擴充：greenlet (sqlalchemy)、某些 grpcio 建置、
  某些 torch 建置
- FFI 中含 C++ 的現代 C++ Rust crates

### Rust (rustup)

由 rustup 安裝的工具鏈仍可在 glibc 2.17+ 上運行。從原始碼建置 Rust
crates 則需要**支援該 crate 語言需求的 C 編譯器**：

- **大多數 crates**：gcc 4.8.5 OK（C99 已足夠）。
- **含 C++ 依賴的 crates**（例如 `clang-sys`、`bindgen`）：通常需要
  gcc 5+ 以支援 C++11。
- **拉入 `cmake-rs` 的 crates**：取決於 cmake 的 C++ 檢查，可能在舊
  gcc 上失敗。

Rust *二進位*在 EL7 上沒問題。痛點在於下游 Rust crate 有需要現代需求
的 C++ 依賴。變通方案：

- 使用 SCL devtoolset（`devtoolset-9` 或 `-11`）在 EL7 上執行現代 gcc。
- 在 Rocky 9 容器中建置麻煩的 crate 並把二進位複製進去（盡可能 musl
  靜態連結）。

## 為什麼你（無法輕易）在運行中的系統升級 glibc

glibc 是機器上每個動態連結二進位的基礎。升級它需要：

1. 替換 `/lib64/libc.so.6`（以及數十個相關的共享函式庫）
2. 重新啟動**每一個**運行中的行程——核心 (kernel) 不會在執行中重新
   連結行程
3. 信任新的 glibc 與你所有已安裝的二進位 ABI 向後相容（在小版號之間
   通常為真，但即使 2.17 → 2.28 也有數十個邊界案例）
4. 在升級被中斷時仍能撐過動態連結器啟動（半安裝的 glibc 會把機器變磚
   ——沒有 shell、沒有 rescue，只能以救援映像開機）

**實務情況**：在生產機上升級 glibc 等同於重灌 OS。CentOS 7 → Rocky 9
不是 in-place 升級——你必須從新媒體開機並遷移 `/home`。ELevate
（AlmaLinux 遷移工具）可用於 7 → 8 但不支援 7 → 9，且即使 7 → 8 也
有注意事項。

**會需要重開機嗎？**會。完整的核心 + glibc 替換需要重開機。在多使用者
與共享磁碟的老 IDC 機器上：

- 與 IT 排程——他們通常會要求一個維護視窗。
- 先快照 LVM `/`。ELevate 可能在升級中途失敗。
- 其他使用者開啟的 SSH 連線會在機器重開時被砍掉。
- 韌體怪癖：5 年以上的 BIOS/iLO/iDRAC 在核心跳級後可能無法乾淨開機。
  要有 console / IPMI 的計畫。

對單一使用者的開發工作站來說，遷移很單純。對於擁有 3TB RAM 的 224-CPU
共享運算節點，成本效益是：**可能不值得這樣的中斷**——下面的變通方案
代價更低。

## 變通方案，依偏好順序排列

當你無法升級 OS 時，這些方法能讓你在老朽的核心上得到一個還算現代的
堆疊：

### 1. micromamba / conda-forge（無需 sudo、無需升級 glibc）

micromamba 隨附自家的 glibc-2.17 相容二進位，並從 conda-forge 拉入
套件，這些套件會在 env 的 `lib/` 中自帶 glibc/libstdc++。這是「在
EL7 上得到現代 Python + numpy + pandas + pyarrow + pytorch」最乾淨
的途徑，也是取得**現代 Node**最乾淨的方式（Node 在 v18 移除了 EL7
支援，見上面的 Node 表格）。

#### 現代 Python + 科學運算套件

```bash
# Single-binary install, ~/.local/bin/micromamba (~30MB, no sudo)
curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
  | tar -xj -C ~/.local/bin --strip-components=1 bin/micromamba

# Modern Python + dataframe stack — bundles its own libstdc++ from
# conda-forge so EL7's gcc 4.8.5 doesn't matter.
micromamba create -n modern -c conda-forge -y \
  python=3.13 numpy pandas pyarrow polars duckdb
micromamba activate modern
python -c "import numpy, pandas; print(numpy.__version__, pandas.__version__)"
# 2.4.4 2.3.3 (or whatever's current on conda-forge)
```

#### 現代 Node + 基於 npm 的 CLI（Copilot/Codex/Gemini）

這是針對需要 Node 18+ 的 npm 套件在 EL7 上的逃生口。NodeSource 的
Node 16 RPM 可用於安裝，但實際的 CLI 會以 `Unsupported engine:
requires Node >= 20` 失敗。

```bash
# Create an env with Node 22 (current LTS at time of writing). conda-forge
# ships nodejs builds linked against its bundled glibc, so this works on
# EL7's glibc 2.17.
micromamba create -n node22 -c conda-forge -y nodejs=22

# Activate to get node + npm on PATH:
micromamba activate node22
node --version    # v22.x.x
npm --version

# Install the npm-based coding agent CLIs:
npm install -g @anthropic-ai/claude-code   # Claude Code via npm
npm install -g @google/gemini-cli           # Gemini CLI
npm install -g @openai/codex                # OpenAI Codex CLI
npm install -g @github/copilot              # GitHub Copilot CLI
```

要讓這在跨 SSH 工作階段中無縫運作，加到 `~/.bashrc.adhoc`：

```bash
# Auto-activate the Node 22 env for any interactive shell on this host
if [ -x ~/.local/bin/micromamba ]; then
    eval "$(~/.local/bin/micromamba shell hook --shell bash)"
    micromamba activate node22 2>/dev/null || true
fi
```

#### 限制

- conda-forge 的 env 有自己的內部一致性——把 pip 套件與 conda-forge
  libstdc++ 混用通常可行，但偶爾會有 ABI 戲劇。每個 env 堅持單一
  channel。
- env 「根植於」conda-forge 的 libstdc++；用 `LD_LIBRARY_PATH` 覆寫
  跨出 env 之外可能會微妙地破壞東西。
- 每個 env 視工具不同消耗 200MB-1GB+ 磁碟。不是免費的。
- conda-forge nodejs 是新建構的——比 nodejs.org 的當天發布晚 1-2 天
  的微小延遲。

### 2. Apptainer / Singularity / Podman（rootless 容器）

在容器內跑 Rocky 9（或 Ubuntu 24.04），共享 `/home`。容器自帶 glibc
2.34 / libstdc++ 13。主機核心（3.10）對所有東西都不是問題，除了非常
現代的系統呼叫（io_uring、目錄上的 fanotify），而大多數工作負載都不
需要這些。

```bash
# Apptainer is rootless and IDC-friendly — ask IT to install if missing.
apptainer pull docker://rockylinux:9
apptainer shell --bind /home --bind /data1 --bind /data2 rockylinux_9.sif
# Inside the container: glibc 2.34, gcc 11, all modern tooling.
```

限制：需要 Apptainer 或 Podman（rootless Docker）由 IT 安裝。一般
Docker 通常需要 root。

### 3. SCL devtoolset（在 EL7 上的現代 gcc，RPM）

Software Collections 給你 `gcc 9` / `gcc 11` / `gcc 12`，同時保持
系統 gcc 4.8.5 不被動到。安裝在 `/opt/rh/`。

```bash
sudo yum install -y centos-release-scl
sudo yum install -y devtoolset-11
scl enable devtoolset-11 bash
gcc --version    # 11.x
```

讓你能編譯需要現代 gcc 的 crates / wheels，但對於鎖定 glibc-2.17 的
二進位沒有幫助。

### 4. 靜態 / musl 二進位

許多 CLI 都會發布 `*-x86_64-unknown-linux-musl` 的版本，這些版本靜態
連結 musl libc，不在乎 glibc。ripgrep、fd、zoxide、eza、bat、fzf 都
這樣做。

我們在 [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) 中已經偏好 musl——見其中
的 "glibc-2.17 fallout" 段落。

### 5. 用較舊的工具鏈從原始碼建置

最後手段。從原始碼建置出問題的套件，鎖定到仍支援你 glibc 的版本。

- **Node**：NodeSource Node 16（如上）——已 EOL 但能用。
- **numpy**：鎖定到 1.26.4——最後一個 manylinux_2_17 發行版。
- **pyarrow**：鎖定到 13.x——同樣的邊界。
- **mlflow**：避免；需要 sqlalchemy → greenlet 會編譯現代 C++。見
  [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md)。

## EL7 上的編輯器堆疊（LazyVim / nvim 變通方案）

現代終端編輯器堆疊會拉入許多會撞到上述 EL7 牆面的元件：

- **Neovim 0.11+**：透過 AppImage（靜態連結）可用——二進位本身在
  glibc 2.17 上沒問題。
- **LazyVim plugin manager**：透過 Mason 的許多 LSP 伺服器假設
  `node` ≥ 18，加上 tree-sitter-cli 從原始碼建置需要現代 Rust。
- **Mason**（LSP 安裝器）：下載的 npm/pip/cargo 套件可能本身需要
  GCC ≥ 9。
- **nvim-treesitter parser builds**：使用 `tree-sitter-cli`，在 EL7
  上 cargo 路徑會失敗（libclang ABI 不符——見
  [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md)
  的同一 bindgen+EL7 陷阱）。npm 安裝路徑需要 Node 18+。

按你想保留多少功能分為三層的逃生口：

### A. Helix — 零 Node、單一二進位、最低摩擦

Helix（`hx`）是一個 Rust 模式編輯器，**內建 LSP 與 tree-sitter**
支援。預編譯的 parsers 隨 release tarball 一起發行；LSP 支援是一行
設定，指到任何 LSP 二進位都能跑。沒有 plugin 語言、沒有 Node、沒有
Mason。

```bash
# Install (no sudo, single binary)
curl -fsSL https://github.com/helix-editor/helix/releases/latest/download/helix-25.07-x86_64-linux.tar.xz \
  | tar -xJ -C /tmp
mkdir -p ~/.local/share/helix
cp -r /tmp/helix-*/runtime ~/.local/share/helix/
cp /tmp/helix-*/hx ~/.local/bin/hx
hx --version
hx --health    # check which languages have LSP/parser support out of the box
```

大多數語言「就是能用」——Go、Rust、Python (pyright/ruff)、TypeScript、
Lua、Shell、Markdown、YAML、TOML 都已內建。對於未內建的 LSP（一些
冷門語言），透過 cargo / micromamba 安裝並加到
`~/.config/helix/languages.toml`：

```toml
[language-server.pyright]
command = "/home/user/.local/share/mamba/envs/modern/bin/pyright-langserver"
args = ["--stdio"]
```

當這對你的語言可行時，這就是 **EL7 上最乾淨的路徑**——沒有 Node、
沒有 Mason、沒有 glibc 雜耍。失去的：VimL plugin 生態系、telescope、
dap、整個 nvim plugin 文化。

### B. Neovim AppImage + 精簡設定（最接近 LazyVim 的使用體驗）

如果你想要 LazyVim 風格的體驗，但不要在 EL7 上會壞掉的 Mason/npm
部分：

```bash
# Statically-linked Neovim AppImage — runs on glibc 2.17
curl -fsSL https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.appimage \
  -o ~/.local/bin/nvim
chmod +x ~/.local/bin/nvim
nvim --version    # 0.11+

# AppImageLauncher / fuse2 not needed if you extract:
~/.local/bin/nvim --appimage-extract -o /tmp/nvim-extract
ln -sf /tmp/nvim-extract/usr/bin/nvim ~/.local/bin/nvim
```

接著在你的 LazyVim 設定中**停用 Mason**，並透過在 EL7 上可用的工具鏈
安裝 LSP 伺服器：

```lua
-- lua/plugins/disable-mason.lua
return {
  { "williamboman/mason.nvim", enabled = false },
  { "williamboman/mason-lspconfig.nvim", enabled = false },
  { "WhoIsSethDaniel/mason-tool-installer.nvim", enabled = false },
}
```

手動安裝 LSP 伺服器：

| LSP | EL7 安裝 |
|-----|-------------|
| `pyright` | `micromamba create -n lsp -c conda-forge pyright` |
| `lua-language-server` | 來自 [LuaLS releases](https://github.com/LuaLS/lua-language-server/releases) 的 musl AppImage |
| `bash-language-server` | 需要 Node 18+——透過 micromamba 的 node22 env 安裝 |
| `gopls` | `go install golang.org/x/tools/gopls@latest`（從官方 tarball 取得 Go 1.21+，glibc 2.17 OK） |
| `rust-analyzer` | 與 rustup 一起；`rustup component add rust-analyzer` |
| `taplo` (TOML) | `cargo install taplo-cli --locked` |
| `marksman` (Markdown) | 來自 [marksman releases](https://github.com/artempyanykh/marksman/releases) 的 musl 二進位 |

對於 tree-sitter parsers，**完全跳過從原始碼建置的路徑**，使用
`nvim-treesitter` 隨附的預編譯 parsers：

```lua
-- lua/plugins/treesitter-prebuilt.lua
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      -- Use prebuilt parsers (downloaded by nvim-treesitter from upstream
      -- releases) instead of compiling locally via tree-sitter-cli.
      -- Requires nvim-treesitter v0.10+ which has the prebuilt-parser flow.
      auto_install = false,
      ensure_installed = {
        "lua", "vim", "vimdoc", "query",
        "python", "rust", "go", "typescript", "tsx", "json", "yaml", "toml",
        "bash", "markdown", "markdown_inline",
      },
    },
  },
}
```

相比完整 LazyVim 失去的：**必須**透過 Mason 安裝的工具（某些 formatter、
debugger）。視需要手動加入。

### C. VSCode Remote SSH — 日常工作最務實的選擇

如果你的筆電跑 VSCode，這就是 EL7 上日常編輯**最低成本的路徑**：

- VSCode 會把 `vscode-server` 推到遠端。該伺服器以內附 glibc 相容層
  建置——在 EL7 的 glibc 2.17 上能跑。
- 所有 LSP / formatters / TypeScript 伺服器都跑在遠端的
  `vscode-server` 中。你不必自己安裝。
- 本地筆電 UI 處理語法高亮、IntelliSense、diff 檢視、原始碼控制、
  除錯。
- EL7 伺服器只做檔案 IO + 跑你的建置指令。

EL7 上要安裝什麼：什麼都不用——VSCode 會在第一次連線時自動把
`vscode-server` 安裝到 `~/.vscode-server/`。如果你的 IT 把 VSCode 的
直接下載擋掉，把 `Remote.SSH: Server Download URL Template` 設成一個
鏡像即可。

權衡：需要在你的筆電上安裝 VSCode（Electron 應用，~500MB）——不是
純 CLI 解法。有些使用者不喜歡快速按鍵操作的延遲，但對於「編輯一些
檔案、跑一些指令、看 git diff」通常沒問題。

這是 **2026 年大多數工程師在遠端 EL7 開發主機上使用的方案**。Helix
與精簡版 Neovim 是替代方案，適合純 SSH 工作階段或快速遠端調整時，
打開 VSCode 顯得太重的場合。

### 決策矩陣

| 編輯器 | EL7 上的設定時間 | LSP 涵蓋度 | 純 SSH 中可用 | 與 nvim 熟悉度 |
|--------|-------------------|--------------|-------------------|---------------------|
| Helix | ~5 分鐘 | 多數語言內建 | ✅ | 一半（modal、無 plugin 語言） |
| Neovim AppImage + slim | ~30 分鐘（Mason 替代工作） | 每語言手動設定 | ✅ | 是（完整 LazyVim 體驗） |
| VSCode Remote SSH | ~2 分鐘 | 全部（由 VSCode 處理） | ❌（需要 VSCode UI） | 否 |

我對「我有一台 CentOS 7 開發機，本地用 macOS」的建議：

- **日常工作**：VSCode Remote SSH。最乾淨、零摩擦。
- **純 SSH 工作階段中的快速編輯**（手邊沒 VSCode）：Helix（`hx`）。
- **你真的想要 LazyVim 對等體驗**：Neovim AppImage + slim，接受
  ~30 分鐘的一次性設定。

## 決策樹

當你撞到 `GLIBC_*` / `GLIBCXX_*` / `CXXABI_*` not-found 錯誤時：

1. **這個二進位是你能換掉的 CLI 嗎？**找 musl 變體（ripgrep、fd 等）
   或用系統套件的對等工具。
2. **是 Python 嗎？**用 micromamba + conda-forge。略過 pip。
3. **是 Node 嗎？**用 NodeSource Node 16（EL7）或升級 OS。
4. **是 C++ 嗎？**試試 SCL devtoolset 從原始碼重建。如果該專案鎖定
   你在 EL7 上拿不到的 C++ stdlib 功能，就把它包在 Apptainer 裡。
5. **它對生產關鍵且你會持續使用 EL7 ≥1 年嗎？**請 IT 排程 OS 遷移。
   一個 6 年舊的 glibc 自 2018 年起就一直在累積 CVE——光是安全性就
   足以正當化這個維護視窗。

## 此 repo 如何處理 EL7

本 repo 中的 chezmoi 設定 + ansible roles 在數處偵測 EL7 並繞過最糟
的情況：

| 介面 | EL7 上的行為 |
|---------|------------------|
| `dot_config/mise/config.toml.tmpl` | 跳過 `node`/`bun`/`rust`/`dotnet` 的 mise pin（這份文件的孿生兄弟）。使用者透過 NodeSource 跑 Node、透過直接 rustup 跑 Rust。 |
| `dot_ansible/roles/python_uv_tools/tasks/main.yml` | 探測 `gcc -dumpversion`，跳過標記 `needs_modern_gcc: true` 的工具（visidata、sqlit-tui[ssh]、mlflow）。 |
| `run_once_before_00_bootstrap.sh.tmpl` | 偵測 `glibc < 2.28`，直接偏好 mise 的 musl 二進位。 |
| `dot_ansible/roles/zsh/tasks/main.yml` | 偵測 `zsh < 5.3`，從原始碼以使用者層級建置 zsh 5.9。 |
| `dot_ansible/roles/{base,zsh,bash,ruby_gem_tools}/` | 使用 `yum` CLI 而非 `ansible.builtin.yum`（後者經由 EL7 上缺失的 `dnf` 後端）。 |
| `pitfalls/centos7-*.md` | 其他所有狀況的 symptom-grep-able pitfall 集合。 |

交叉連結的 pitfalls：

- [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) — noRoot 路徑、glibc 2.17 musl 後備故事。
- [`pitfalls/centos7-numpy-pandas-source-build.md`](../../pitfalls/centos7-numpy-pandas-source-build.md) — numpy 2.x 的 meson 牆。
- [`pitfalls/centos7-zsh-too-old.md`](../../pitfalls/centos7-zsh-too-old.md) — 系統 zsh 5.0.2 vs. 設定需求。
- [`pitfalls/centos7-ansible-yum-dnf-backend.md`](../../pitfalls/centos7-ansible-yum-dnf-backend.md) — ansible-core 2.18+ yum module 包裝器。
- [`pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md`](../../pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md) — sudo session + Linuxbrew 安裝器。
- [`pitfalls/tuna-nodejs-mirror-aggressive-gc.md`](../../pitfalls/tuna-nodejs-mirror-aggressive-gc.md) — TUNA 鏡像只保留少數 node 版本。

## 參考資料

- glibc release tags：<https://sourceware.org/glibc/wiki/Release>
- gcc release tags：<https://gcc.gnu.org/releases.html>
- libstdc++ ABI 符號版本表：
  <https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html>
- manylinux PEPs：600 (2014/`_2_17`)、656 (`_2_28`)、690 (`_2_34`)
- NodeSource distribution policy：
  <https://github.com/nodesource/distributions>
- Rocky Linux 遷移指南（in-place 的替代方案）：
  <https://docs.rockylinux.org/release_notes/9_3/>
- ELevate（AlmaLinux project）用於 7→8：
  <https://wiki.almalinux.org/elevate/>
