# .NET 工具

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

在 `chezmoi init` 期間以 `installDotnetTools = true` 選用。此角色 (role) 會：

1. 透過 [mise](https://mise.jdx.dev/) 安裝 .NET SDK（`mise use -g dotnet@latest`）—— 與 `rust_cargo_tools` 用於 Rust 相同的機制，因此不必再走 `brew install dotnet`／Microsoft apt repo／`dotnet-install.sh` 那套流程。
2. 迭代 [`dotnet_tools`](../../dot_ansible/roles/dotnet_tools/defaults/main.yml) 清單，對每個項目執行 `dotnet tool install --global <pkg>`。二進位會落到 `~/.dotnet/tools`，當該目錄存在時，會由 [`00_exports.zsh`](../../dot_config/zsh/00_exports.zsh.tmpl) 自動加進 `PATH`。

預設附帶的工具：

| 工具 | 二進位 | 說明 |
|------|--------|-------------|
| [azure-cost-cli](https://github.com/mivano/azure-cost-cli) | `azure-cost` | 針對 Azure 訂閱 (subscription) 做成本分析／異常偵測／預算／CI 成本門檻 |

要新增更多工具，編輯 `dot_ansible/roles/dotnet_tools/defaults/main.yml`：

```yaml
dotnet_tools:
  - name: azure-cost-cli
    binary: azure-cost
  - name: dotnet-ef          # EF Core CLI
    binary: dotnet-ef
  - name: PowerShell         # 跨平台 PowerShell
    binary: pwsh
```

## 為什麼用 mise？

- **整個 stack 用同一套 SDK 管理器。** 在本 repo 中 mise 已經負責 Node.js／Rust／（選擇性的）Python。把 `dotnet` 加進來，所有語言執行期 (runtime) 都集中在 `~/.local/share/mise/installs/` 之下。
- **不需 sudo／不需系統套件管理器。** `mise use -g dotnet@latest` 在 macOS、有 sudo 的 Ubuntu、Ubuntu `noRoot` 上行為一致。對比之下，先前的設定要看平台來選 `brew install dotnet`、`packages-microsoft-prod.deb`、或 `dotnet-install.sh`。
- **全域版本鎖定 (pin) 存在 `~/.config/mise/config.toml`。** `mise upgrade dotnet` 可以乾淨地升級，其他 mise 工具仍維持各自鎖定的版本。
- **PATH 上有 shim。** 一旦 mise 在 zsh 中啟用，`~/.local/share/mise/shims/dotnet` 會自動解析 `dotnet`。

## 快速上手

```bash
# 在 chezmoi init 期間
chezmoi init --force   # 重新提示；對 installDotnetTools 答 y

# 或者臨時手動執行
ansible-playbook ~/.ansible/playbooks/macos.yml --tags dotnet_tools

# 驗證
dotnet --version
azure-cost --help
```

## azure-cost-cli 用法

[`azure-cost-cli`](https://github.com/mivano/azure-cost-cli) 包裝 Azure Cost Management API。它會重複利用同一個 `az login` session，因此只要 Azure CLI（來自 [iac_tools 角色](./infrastructure-as-code.md)）已驗證，它就「直接能用」。

```bash
# 累計成本（當前帳單月份、目前訂閱）
azure-cost accumulatedCost

# 指定訂閱、強制以 USD 表示
azure-cost accumulatedCost -s <sub-id> --useUSD

# 成本最高的前 10 筆資源、markdown 輸出（PR 留言／Job Summary 用）
azure-cost costByResource --top 10 -o markdown

# 依服務分組的每日趨勢
azure-cost dailyCosts --dimension MeterCategory

# 對最近 7 天做異常偵測
azure-cost detectAnomalies --recent-activity-days 7

# 依標籤計算成本（給團隊回報 show-back）
azure-cost costByTag --tag cost-center --tag owner

# 預算 + 🟢 OK / 🟡 AT-RISK / 🔴 EXCEEDED 狀態
azure-cost budgets

# CI 成本門檻：總額 > $500 時離開碼 1
azure-cost accumulatedCost -s <sub-id> -o json --fail-if-over 500 > costs.json
```

驗證 (authentication) 備註：

- 使用 `ChainedTokenCredential` —— 先抓 `az login`，再走環境變數／managed identity
- 帳號需要在目標範圍上有 **Cost Management Reader** 權限
- 並非所有訂閱類型都會公開 Cost Management API（贊助方案、CSP 等級）。請見[上游 README](https://github.com/mivano/azure-cost-cli#usage)了解 quota-id 相容性檢查。

## 升級

```bash
# 升級 .NET SDK（由 mise 管理）
mise upgrade dotnet
# 或鎖定特定 channel
mise use -g dotnet@8

# 升級特定的全域工具
dotnet tool update --global azure-cost-cli

# 列出已安裝的 dotnet 全域工具
dotnet tool list --global
```

## 疑難排解

### 安裝後出現 `dotnet: command not found`

dotnet 二進位是透過 mise shim 引入。確認 `mise activate` 已在你的 shell 中執行：

```bash
# 檢查 shim
ls ~/.local/share/mise/shims/dotnet

# 重新啟用 mise（理論上應該已經由 shell config 載入）
eval "$(mise activate zsh)"
```

### `azure-cost: command not found`

`dotnet tool install --global` 把二進位放在 `~/.dotnet/tools`。該目錄只在存在時才會被 [`~/.config/zsh/00_exports.zsh`](../../dot_config/zsh/00_exports.zsh.tmpl) 加到 `PATH` 前面，所以首次安裝後請開新的 shell：

```bash
ls ~/.dotnet/tools/          # 應該會看到 azure-cost
echo $PATH | tr ':' '\n' | rg dotnet
exec zsh                     # 重新讀取 PATH
```

如果用的是 bash，請手動加入：

```bash
echo 'export PATH="$HOME/.dotnet/tools:$PATH"' >> ~/.bashrc
```

### 角色執行時找不到 `mise`

當 mise 未安裝時，角色會拒絕繼續並印出 skip 警告。mise 屬於 bootstrap 階段
（見 [`run_once_before_00_bootstrap.sh.tmpl`](../../run_once_before_00_bootstrap.sh.tmpl)），
所以常見原因是 bootstrap 執行不完整。請重新執行：

```bash
curl https://mise.run | sh
chezmoi apply
```

## 相關連結

- [mise dotnet plugin (asdf-dotnet)](https://github.com/mise-plugins/mise-dotnet)
- [dotnet tool install 文件](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-tool-install)
- [NuGet 上的 dotnet 全域工具搜尋](https://www.nuget.org/packages?packagetype=dotnettool)
- [docs/tools/infrastructure-as-code.md](./infrastructure-as-code.md) —— Azure CLI／Terraform／OpenTofu（獨立的 `installIacTools` 選用；這裡的 `az login` 是 `azure-cost` 的驗證來源）
