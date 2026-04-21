# Infrastructure-as-Code Tools

Opt-in via `installIacTools = true` during `chezmoi init`. Installs:

| Tool | Binary | Description |
|------|--------|-------------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/?view=azure-cli-latest) | `az` | Manage Azure resources from the command line |
| [Terraform](https://developer.hashicorp.com/terraform) | `terraform` | HashiCorp's infrastructure provisioning tool (BSL license) |
| [OpenTofu](https://opentofu.org/) | `tofu` | Linux Foundation fork of Terraform (MPL-2.0 license) |

Related add-ons (separate opt-in):

- **Azure cost & .NET tooling** — [`azure-cost-cli`](https://github.com/mivano/azure-cost-cli) for cost analysis, anomaly detection, and CI cost gates. Handled by the dedicated [dotnet_tools role](./dotnet-tools.md) (separate `installDotnetTools` toggle) so enabling IaC CLIs doesn't drag in the .NET SDK.

Terraform and OpenTofu install side-by-side (different binary names) — no conflict.

## Installation matrix

| Platform | Azure CLI | Terraform | OpenTofu |
|----------|-----------|-----------|----------|
| macOS | `brew install azure-cli` | `hashicorp/tap/terraform` | `brew install opentofu` |
| Linux (sudo) | Microsoft apt repo | HashiCorp apt repo | OpenTofu deb repo |
| Linux (noRoot) | `uv tool install azure-cli` | GitHub release → `~/.local/bin/` | GitHub release → `~/.local/bin/` |

### Per-tool toggles

The role installs all three by default. Disable individual tools via `--extra-vars`:

```bash
cd ~/.ansible
ansible-playbook playbooks/macos.yml --tags iac_tools \
  --extra-vars "iac_install_terraform=false"
```

Available per-tool flags (all boolean, default `true`):

- `iac_install_azure_cli` → `az`
- `iac_install_terraform` → `terraform`
- `iac_install_opentofu` → `tofu`

For `azure-cost-cli` and other .NET global tools, see the [dotnet_tools role docs](./dotnet-tools.md).

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

> **Azure cost analysis:** for `azure-cost-cli` (anomaly detection, daily trends, CI cost gates) see [docs/tools/dotnet-tools.md](./dotnet-tools.md) — it rides on the shared `installDotnetTools` opt-in so the .NET SDK isn't forced on IaC users.

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
