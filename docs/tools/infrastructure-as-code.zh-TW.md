# 基礎建設即程式碼 (Infrastructure-as-Code) 工具

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

於 `chezmoi init` 過程中設定 `installIacTools = true` 即可選用 (opt-in)。會安裝：

| 工具 | 執行檔 | 描述 |
|------|--------|-------------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest) | `az` | 從命令列管理 Azure 資源 |
| [Terraform](https://developer.hashicorp.com/terraform) | `terraform` | HashiCorp 的基礎建設配置 (provisioning) 工具（BSL 授權） |
| [OpenTofu](https://opentofu.org/) | `tofu` | Linux Foundation 對 Terraform 的分支 (fork)（MPL-2.0 授權） |

相關附加項目（獨立選用）：

- **Azure 成本與 .NET 工具鏈** —— [`azure-cost-cli`](https://github.com/mivano/azure-cost-cli) 用於成本分析、異常偵測 (anomaly detection) 與 CI 成本守門 (cost gate)。由專屬的 [dotnet_tools role](./dotnet-tools.md)（獨立的 `installDotnetTools` 開關）負責，因此啟用 IaC CLI 不會連帶把 .NET SDK 拉進來。

Terraform 與 OpenTofu 並列安裝（執行檔名稱不同）—— 不會衝突。

## 安裝矩陣

| 平台 | Azure CLI | Terraform | OpenTofu |
|----------|-----------|-----------|----------|
| macOS | `brew install azure-cli` | `hashicorp/tap/terraform` | `brew install opentofu` |
| Linux（sudo） | Microsoft apt repo | HashiCorp apt repo | OpenTofu deb repo |
| Linux（noRoot） | `uv tool install azure-cli` | GitHub release → `~/.local/bin/` | GitHub release → `~/.local/bin/` |

### 各工具的開關

該 role 預設安裝三個工具。透過 `--extra-vars` 個別停用：

```bash
cd ~/.ansible
ansible-playbook playbooks/macos.yml --tags iac_tools \
  --extra-vars "iac_install_terraform=false"
```

可用的個別開關（皆為布林值，預設 `true`）：

- `iac_install_azure_cli` → `az`
- `iac_install_terraform` → `terraform`
- `iac_install_opentofu` → `tofu`

關於 `azure-cost-cli` 與其他 .NET 全域工具，請參見 [dotnet_tools role 文件](./dotnet-tools.md)。

## 快速參考

### Azure CLI

**完整指令參考：** <https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest> —— 每個指令群組（`az vm`、`az aks`、`az storage`、`az keyvault`、`az network`、……）都附有參數與範例。

```bash
# ── 認證與訂閱 ──────────────────────────────────
az login                                      # 互動式瀏覽器登入
az login --use-device-code                    # 無頭 (headless) / SSH 工作階段
az login --tenant <tenant-id>                 # 多租戶 (multi-tenant) 帳號
az account show                               # 目前的訂閱
az account list -o table                      # 你能看到的所有訂閱
az account set --subscription "<name-or-id>"  # 切換目前訂閱

# ── 資源群組與通用資源 ──────────────────────────
az group list -o table
az group create -n <rg> -l <region>
az resource list -g <rg> -o table
az resource show --ids <resource-id>

# ── 計算 / VM / AKS ──────────────────────────────
az vm list -d -o table                        # -d = 顯示電源狀態
az vm start/stop/deallocate --ids <id>
az aks list -o table
az aks get-credentials -g <rg> -n <cluster>   # 合併 kubeconfig

# ── 儲存體、Key Vault、網路 ─────────────────────
az storage account list -o table
az keyvault list -o table
az network vnet list -o table

# ── 擴充功能（az CLI 外掛） ─────────────────────
az extension list-available -o table          # 探索擴充功能
az extension add --name <ext-name>
az extension update --name <ext-name>

# ── 輸出格式與 JMESPath 查詢 ────────────────────
az group list -o json                         # json | jsonc | yaml | table | tsv
az vm list --query "[].{name:name, rg:resourceGroup, size:hardwareProfile.vmSize}" -o table

# ── 自我升級 ─────────────────────────────────────
az upgrade                                    # 內建自我升級（任何 OS）
# macOS: brew upgrade azure-cli
# Linux: sudo apt-get update && sudo apt-get install --only-upgrade azure-cli
```

實用參考：

- [完整指令參考（最新版）](https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest)
- [安裝指南](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [JMESPath `--query` 食譜](https://learn.microsoft.com/en-us/cli/azure/query-azure-cli)
- [管理擴充功能](https://learn.microsoft.com/en-us/cli/azure/azure-cli-extensions-overview)

> **Azure 成本分析：** `azure-cost-cli`（異常偵測、每日趨勢、CI 成本守門）的說明請見 [docs/tools/dotnet-tools.md](./dotnet-tools.md) —— 它搭著共用的 `installDotnetTools` 選項一起運作，因此不會強迫 IaC 使用者裝上 .NET SDK。

### Terraform

```bash
# 初始化專案（下載 provider）
terraform init

# 預覽變更
terraform plan

# 套用變更
terraform apply

# 摧毀基礎建設
terraform destroy

# 格式化設定檔
terraform fmt

# 驗證設定
terraform validate

# 顯示目前狀態
terraform show
```

文件：<https://developer.hashicorp.com/terraform/docs>

### OpenTofu

OpenTofu 是 Terraform 的可直接替換 (drop-in replacement) 方案。相同的 HCL 語法、相同的 provider 生態系。把所有指令裡的 `terraform` 替換成 `tofu` 即可：

```bash
tofu init
tofu plan
tofu apply
tofu destroy
```

文件：<https://opentofu.org/docs/>

## Terraform 與 OpenTofu 比較

| 面向 | Terraform | OpenTofu |
|--------|-----------|----------|
| 授權 | BSL 1.1（source-available，非 OSS） | MPL-2.0（真正的開放原始碼） |
| 治理 (governance) | HashiCorp / IBM | Linux Foundation（CNCF） |
| 相容性 | — | 以 Terraform 1.x 相容為目標 |
| Provider registry | registry.terraform.io | registry.opentofu.org（鏡像 Terraform） |
| 狀態 (state) 格式 | 相容 | 相容 |

**何時使用何者：**

- **OpenTofu** —— 新專案建議優先選擇；開放原始碼授權、社群治理、相同語法
- **Terraform** —— 當你的團隊／組織已經以它為標準，或你需要 HashiCorp 企業功能（Terraform Cloud、Sentinel policies）
- **兩者都安裝** —— 適合把既有的 Terraform 專案逐步遷移到 OpenTofu

## 版本管理

該 Ansible role 透過 OS 套件管理員 (package manager)（Homebrew／apt repo）安裝最新穩定版。如果需要按專案鎖定版本，可以考慮：

- [tfenv](https://github.com/tfutils/tfenv) —— Terraform 版本管理器
- [tofuenv](https://github.com/tofuutils/tofuenv) —— OpenTofu 版本管理器
- [mise](https://mise.jdx.dev/) —— 多語系版本管理器（同時支援 `terraform` 與 `opentofu`）

預設不會安裝這些工具，但你可以手動加入。

## 疑難排解

### macOS：brew install 過程中出現 `curl: (18) Transferred a partial file`

Homebrew 會從 `ghcr.io` 下載 bottle，在某些網路環境（ISP 限速、GFW 等）可能緩慢或不穩定。症狀：單次 `brew install azure-cli` / `terraform` / `opentofu` 耗時超過 10 分鐘，偶爾還會在下載中途失敗。

`iac_tools` role 已對每個 brew install 重試 3 次、間隔 20 秒，並把每個工具包在各自的 rescue 區塊裡，這樣單一失敗不會讓其他工具也停下來。如果你仍然持續失敗：

1. **手動重試** —— brew 會接續未完成的下載：

   ```bash
   brew install azure-cli terraform opentofu
   ```

2. **啟用內建 TUNA 鏡像**（針對 GFW 建議使用）。若你在 `chezmoi init` 時對 `useChineseMirror` 回答 `y`，下方四個 `HOMEBREW_*` 環境變數已經在三個地方匯出 —— 完整覆蓋對應表請看 [docs/tools/mirrors.md](./mirrors.md)：

   - `~/.config/zsh/00_exports.zsh` —— 給互動式 shell 使用
   - `run_once_before_00_bootstrap.sh` —— 給首次執行的 Homebrew 安裝程式使用
   - `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh` —— 讓 ansible 的 `community.general.homebrew` 子行程也能繼承

   如果你在 init 時沒有啟用，重跑 `chezmoi init`（或編輯 `~/.config/chezmoi/chezmoi.toml` 設定 `useChineseMirror = true`），然後 `chezmoi apply`。要為單次工作階段手動設定：

   ```bash
   # 清華鏡像（中国大陆） —— 參見 https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/
   export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
   export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
   export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
   export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
   ```

   其他選擇（USTC、SJTU 等）請見 [Homebrew 環境變數文件](https://docs.brew.sh/Manpage#environment)。

3. **退而求其次：從 GitHub releases 取得 Terraform/OpenTofu** —— 它們是單一靜態執行檔，不需要 Homebrew：

   ```bash
   # Terraform
   curl -LO https://releases.hashicorp.com/terraform/$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)/terraform_$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)_darwin_arm64.zip
   unzip terraform_*_darwin_arm64.zip -d ~/.local/bin/

   # OpenTofu
   VERSION=$(gh release view -R opentofu/opentofu --json tagName -q .tagName | sed 's/^v//')
   curl -LO "https://github.com/opentofu/opentofu/releases/download/v${VERSION}/tofu_${VERSION}_darwin_arm64.zip"
   unzip "tofu_${VERSION}_darwin_arm64.zip" -d ~/.local/bin/
   ```

### Linux：apt repo 金鑰／簽章問題

若 `apt update` 抱怨 Microsoft / HashiCorp / OpenTofu 金鑰，該 role 會把 keyring 安裝到：

- Azure CLI：`/etc/apt/keyrings/microsoft.gpg` + `/etc/apt/sources.list.d/azure-cli.list`
- Terraform：`/usr/share/keyrings/hashicorp-archive-keyring.gpg` + `/etc/apt/sources.list.d/hashicorp.list`
- OpenTofu：`/etc/apt/keyrings/opentofu.gpg` + `/etc/apt/keyrings/opentofu-repo.gpg` + `/etc/apt/sources.list.d/opentofu.list`

要強制重新建立，刪除 keyring 與 source list 檔，然後重跑該 role：

```bash
cd ~/.ansible
ansible-playbook playbooks/linux.yml --tags iac_tools
```

## 相關連結

- [Azure CLI 安裝文件](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Terraform 安裝文件](https://developer.hashicorp.com/terraform/install)
- [OpenTofu 安裝文件](https://opentofu.org/docs/intro/install/)
- [Homebrew 環境變數](https://docs.brew.sh/Manpage#environment) —— `HOMEBREW_BOTTLE_DOMAIN`、`HOMEBREW_API_DOMAIN` 等。
- [docs/infra/](../infra/) —— Terraform/OpenTofu 將會配置的基礎建設本身：虛擬化 (Proxmox / ESXi / KubeVirt)、共享儲存 (CephFS / BeeGFS)、計算排程 (SLURM / Kubernetes)、身分認證 (FreeIPA)。IaC 是「如何配置 (how to provision)」；那個資料夾則是「你正在配置的對象 (what you're provisioning)」。
