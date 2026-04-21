# Infrastructure-as-Code Tools

Opt-in via `installIacTools = true` during `chezmoi init`. Installs:

| Tool | Binary | Description |
|------|--------|-------------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) | `az` | Manage Azure resources from the command line |
| [Terraform](https://developer.hashicorp.com/terraform) | `terraform` | HashiCorp's infrastructure provisioning tool (BSL license) |
| [OpenTofu](https://opentofu.org/) | `tofu` | Linux Foundation fork of Terraform (MPL-2.0 license) |

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

## Quick reference

### Azure CLI

```bash
# Login (opens browser)
az login

# Set default subscription
az account set --subscription "<name-or-id>"

# List resource groups
az group list -o table

# Show current account
az account show

# Manage extensions
az extension list
az extension add --name <extension-name>

# Update Azure CLI itself
# macOS: brew upgrade azure-cli
# Linux: sudo apt-get update && sudo apt-get install --only-upgrade azure-cli
```

Docs: <https://learn.microsoft.com/en-us/cli/azure/>

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

2. **Enable the built-in TUNA mirror** (recommended for GFW). If you answered `y` to `useChineseMirror` at `chezmoi init`, the four `HOMEBREW_*` env vars below are already exported in three places:

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
