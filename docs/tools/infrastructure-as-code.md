# Infrastructure-as-Code Tools

Opt-in via `installIacTools = true` during `chezmoi init`. Installs:

| Tool | Binary | Description |
|------|--------|-------------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest) | `az` | Manage Azure resources from the command line |
| [Terraform](https://developer.hashicorp.com/terraform) | `terraform` | HashiCorp's infrastructure provisioning tool (BSL license) |
| [OpenTofu](https://opentofu.org/) | `tofu` | Linux Foundation fork of Terraform (MPL-2.0 license) |

Optional add-ons (opt-in per-tool, default off):

| Tool | Binary | Flag (--extra-vars) | Description |
|------|--------|---------------------|-------------|
| [azure-cost-cli](https://github.com/mivano/azure-cost-cli) | `azure-cost` | `iac_install_azure_cost_cli=true` | Cost analysis / anomaly detection for Azure subscriptions (requires .NET SDK) |

Terraform and OpenTofu install side-by-side (different binary names) — no conflict.

## Installation matrix

| Platform | Azure CLI | Terraform | OpenTofu | azure-cost-cli (opt-in) |
|----------|-----------|-----------|----------|--------------------------|
| macOS | `brew install azure-cli` | `hashicorp/tap/terraform` | `brew install opentofu` | `brew install dotnet` → `dotnet tool install -g` |
| Linux (sudo) | Microsoft apt repo | HashiCorp apt repo | OpenTofu deb repo | `dotnet-sdk-8.0` via Microsoft repo → `dotnet tool install -g` |
| Linux (noRoot) | `uv tool install azure-cli` | GitHub release → `~/.local/bin/` | GitHub release → `~/.local/bin/` | `dotnet-install.sh` → `~/.dotnet/` → `dotnet tool install -g` |

### Per-tool toggles

The role installs the three core tools by default. Disable individual tools (or enable the opt-in add-ons) via `--extra-vars`:

```bash
cd ~/.ansible
# Disable Terraform but keep the rest
ansible-playbook playbooks/macos.yml --tags iac_tools \
  --extra-vars "iac_install_terraform=false"

# Enable azure-cost-cli (pulls in .NET SDK as a prerequisite)
ansible-playbook playbooks/macos.yml --tags iac_tools \
  --extra-vars "iac_install_azure_cost_cli=true"
```

Available per-tool flags (all boolean):

| Flag | Default | Installs |
|------|---------|----------|
| `iac_install_azure_cli` | `true` | `az` |
| `iac_install_terraform` | `true` | `terraform` |
| `iac_install_opentofu` | `true` | `tofu` |
| `iac_install_azure_cost_cli` | `false` | `azure-cost` (also installs .NET SDK if missing) |

## Quick reference

### Azure CLI

**Full command reference:** <https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest> — every command group (`az vm`, `az aks`, `az storage`, `az keyvault`, `az network`, ...) is documented there with parameters and examples.

```bash
# ── Auth & subscription ──────────────────────────────────
az login                                      # Interactive browser login
az login --use-device-code                    # Headless / SSH sessions
az login --tenant <tenant-id>                 # Multi-tenant accounts
az account show                               # Current subscription
az account list -o table                      # All subscriptions you can see
az account set --subscription "<name-or-id>"  # Switch active subscription

# ── Resource groups & generic resources ──────────────────
az group list -o table
az group create -n <rg> -l <region>
az resource list -g <rg> -o table
az resource show --ids <resource-id>

# ── Compute / VMs / AKS ──────────────────────────────────
az vm list -d -o table                        # -d = show power state
az vm start/stop/deallocate --ids <id>
az aks list -o table
az aks get-credentials -g <rg> -n <cluster>   # Merge kubeconfig

# ── Storage, Key Vault, networking ───────────────────────
az storage account list -o table
az keyvault list -o table
az network vnet list -o table

# ── Extensions (az CLI plugins) ──────────────────────────
az extension list-available -o table          # Discover extensions
az extension add --name <ext-name>
az extension update --name <ext-name>

# ── Output formats & JMESPath queries ────────────────────
az group list -o json                         # json | jsonc | yaml | table | tsv
az vm list --query "[].{name:name, rg:resourceGroup, size:hardwareProfile.vmSize}" -o table

# ── Self-upgrade ─────────────────────────────────────────
az upgrade                                    # Built-in self-upgrade (any OS)
# macOS: brew upgrade azure-cli
# Linux: sudo apt-get update && sudo apt-get install --only-upgrade azure-cli
```

Useful references:

- [Full command reference (latest)](https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest)
- [Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [JMESPath `--query` cookbook](https://learn.microsoft.com/en-us/cli/azure/query-azure-cli)
- [Managing extensions](https://learn.microsoft.com/en-us/cli/azure/azure-cli-extensions-overview)

### azure-cost-cli (opt-in)

[`azure-cost-cli`](https://github.com/mivano/azure-cost-cli) adds a friendly CLI on top of the Azure Cost Management API — accumulated cost, daily trends, anomaly detection, budget status, `what-if` scenarios, and a cost-gate flag for CI/CD (`--fail-if-over`). It reuses the same `az login` token, so as long as Azure CLI is authenticated it "just works".

**Why opt-in?** It's a .NET 8 global tool (`dotnet tool install --global azure-cost-cli`), so enabling it pulls in the .NET SDK (~400–800MB). The role leaves it off by default; set `iac_install_azure_cost_cli=true` to install it.

Enable + install:

```bash
# One-shot from chezmoi (persists for future runs)
chezmoi apply
ansible-playbook ~/.ansible/playbooks/macos.yml --tags iac_tools \
  --extra-vars "iac_install_azure_cost_cli=true"
```

On `noRoot` Linux the role falls back to Microsoft's [`dotnet-install.sh`](https://learn.microsoft.com/en-us/dotnet/core/install/linux-scripted-manual#scripted-install) which installs the SDK to `$HOME/.dotnet` — no sudo needed.

The role appends `~/.dotnet/tools` to `PATH` via `~/.config/zsh/00_exports.zsh` so `azure-cost` is reachable from a fresh shell. For bash, add manually:

```bash
echo 'export PATH="$HOME/.dotnet/tools:$PATH"' >> ~/.bashrc
```

Quick reference:

```bash
# Accumulated cost (current billing month, active subscription)
azure-cost accumulatedCost

# Pin a specific subscription and force USD
azure-cost accumulatedCost -s <sub-id> --useUSD

# Top 10 costliest resources, markdown output (for PR comments / Job Summary)
azure-cost costByResource --top 10 -o markdown

# Daily trends grouped by service
azure-cost dailyCosts --dimension MeterCategory

# Anomaly detection on the last 30 days
azure-cost detectAnomalies --recent-activity-days 7

# Cost by tag (e.g. show-back to teams)
azure-cost costByTag --tag cost-center --tag owner

# Budgets + 🟢 OK / 🟡 AT-RISK / 🔴 EXCEEDED status
azure-cost budgets

# CI cost gate: exit 1 if total > $500
azure-cost accumulatedCost -s <sub-id> -o json --fail-if-over 500 > costs.json

# Upgrade later (same command, runs under the existing dotnet install)
dotnet tool update --global azure-cost-cli
```

Authentication notes:

- Uses `ChainedTokenCredential` — picks up `az login` first, then env vars / managed identity
- The account needs **Cost Management Reader** (or higher) on the target scope
- Not all subscription types expose the Cost Management API (sponsored / CSP-tier). See the [upstream README](https://github.com/mivano/azure-cost-cli#usage) for the quota-id compatibility check.

### Terraform

```bash
# Init a project (downloads providers)
terraform init

# Preview changes
terraform plan

# Apply changes
terraform apply

# Destroy infrastructure
terraform destroy

# Format config files
terraform fmt

# Validate config
terraform validate

# Show current state
terraform show
```

Docs: <https://developer.hashicorp.com/terraform/docs>

### OpenTofu

OpenTofu is a drop-in replacement for Terraform. Same HCL syntax, same provider ecosystem. Replace `terraform` with `tofu` in all commands:

```bash
tofu init
tofu plan
tofu apply
tofu destroy
```

Docs: <https://opentofu.org/docs/>

## Terraform vs OpenTofu

| Aspect | Terraform | OpenTofu |
|--------|-----------|----------|
| License | BSL 1.1 (source-available, not OSS) | MPL-2.0 (true open source) |
| Governance | HashiCorp / IBM | Linux Foundation (CNCF) |
| Compatibility | — | Aims for Terraform 1.x compatibility |
| Provider registry | registry.terraform.io | registry.opentofu.org (mirrors Terraform) |
| State format | Compatible | Compatible |

**When to use which:**

- **OpenTofu** — preferred for new projects; open-source license, community-governed, same syntax
- **Terraform** — when your team/org already standardizes on it, or you need HashiCorp enterprise features (Terraform Cloud, Sentinel policies)
- **Both installed** — useful for migrating existing Terraform projects to OpenTofu incrementally

## Version management

The Ansible role installs the latest stable version via OS package managers (Homebrew / apt repos). For project-specific version pinning, consider:

- [tfenv](https://github.com/tfutils/tfenv) — Terraform version manager
- [tofuenv](https://github.com/tofuutils/tofuenv) — OpenTofu version manager
- [mise](https://mise.jdx.dev/) — polyglot version manager (supports both `terraform` and `opentofu`)

These are not installed by default but can be added manually.

## Troubleshooting

### macOS: `curl: (18) Transferred a partial file` during brew install

Homebrew downloads bottles from `ghcr.io`, which can be slow or unstable on some networks (ISP throttling, GFW, etc.). Symptoms: single `brew install azure-cli` / `terraform` / `opentofu` taking 10+ minutes and occasionally failing mid-download.

The `iac_tools` role already retries each brew install 3 times with a 20s delay and wraps each tool in its own rescue block so one failure doesn't stop the others. If you still hit persistent failures:

1. **Manually retry** — brew resumes partial downloads:

   ```bash
   brew install azure-cli terraform opentofu
   ```

2. **Enable the built-in TUNA mirror** (recommended for GFW). If you answered `y` to `useChineseMirror` at `chezmoi init`, the four `HOMEBREW_*` env vars below are already exported in three places — see the full coverage map in [docs/tools/mirrors.md](./mirrors.md):

   - `~/.config/zsh/00_exports.zsh` — for interactive shells
   - `run_once_before_00_bootstrap.sh` — for the first-run Homebrew installer
   - `run_onchange_after_20_ansible_roles.sh` — so ansible's `community.general.homebrew` subprocess inherits them

   If you didn't enable it at init, re-run `chezmoi init` (or edit `~/.config/chezmoi/chezmoi.toml` and set `useChineseMirror = true`) then `chezmoi apply`. To set it manually for a one-off session:

   ```bash
   # Tsinghua mirror (中国大陆) — see https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/
   export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
   export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
   export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
   export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
   ```

   See [Homebrew docs on environment variables](https://docs.brew.sh/Manpage#environment) for alternatives (USTC, SJTU, etc.).

3. **Fall back to Terraform/OpenTofu from GitHub releases** — they're single static binaries, no Homebrew needed:

   ```bash
   # Terraform
   curl -LO https://releases.hashicorp.com/terraform/$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)/terraform_$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)_darwin_arm64.zip
   unzip terraform_*_darwin_arm64.zip -d ~/.local/bin/

   # OpenTofu
   VERSION=$(gh release view -R opentofu/opentofu --json tagName -q .tagName | sed 's/^v//')
   curl -LO "https://github.com/opentofu/opentofu/releases/download/v${VERSION}/tofu_${VERSION}_darwin_arm64.zip"
   unzip "tofu_${VERSION}_darwin_arm64.zip" -d ~/.local/bin/
   ```

### Linux: apt repo key / signing issues

If `apt update` complains about Microsoft / HashiCorp / OpenTofu keys, the role installs keyrings to:

- Azure CLI: `/etc/apt/keyrings/microsoft.gpg` + `/etc/apt/sources.list.d/azure-cli.list`
- Terraform: `/usr/share/keyrings/hashicorp-archive-keyring.gpg` + `/etc/apt/sources.list.d/hashicorp.list`
- OpenTofu: `/etc/apt/keyrings/opentofu.gpg` + `/etc/apt/keyrings/opentofu-repo.gpg` + `/etc/apt/sources.list.d/opentofu.list`

To force re-creation, delete the keyring + source list file and re-run the role:

```bash
cd ~/.ansible
ansible-playbook playbooks/linux.yml --tags iac_tools
```

## Related

- [Azure CLI install docs](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Terraform install docs](https://developer.hashicorp.com/terraform/install)
- [OpenTofu install docs](https://opentofu.org/docs/intro/install/)
- [Homebrew environment variables](https://docs.brew.sh/Manpage#environment) — `HOMEBREW_BOTTLE_DOMAIN`, `HOMEBREW_API_DOMAIN`, etc.
- [docs/infra/](../infra/) — the infrastructure itself that Terraform/OpenTofu would provision: virtualization (Proxmox / ESXi / KubeVirt), shared storage (CephFS / BeeGFS), compute scheduling (SLURM / Kubernetes), identity (FreeIPA). IaC is the "how to provision"; that folder is the "what you're provisioning."
