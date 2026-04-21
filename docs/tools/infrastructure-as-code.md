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

## Related

- [Azure CLI install docs](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Terraform install docs](https://developer.hashicorp.com/terraform/install)
- [OpenTofu install docs](https://opentofu.org/docs/intro/install/)
