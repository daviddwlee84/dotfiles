---
name: iac tools ansible role
overview: Add an opt-in `iac_tools` Ansible role that installs Azure CLI, Terraform, and OpenTofu cross-platform, wired through a new `installIacTools` chezmoi prompt, with a docs note under `docs/tools/`.
todos:
  - id: role-tasks
    content: Create dot_ansible/roles/iac_tools/tasks/main.yml with macOS Homebrew, Linux apt (sudo), and Linux user-level (noRoot) blocks for Azure CLI / Terraform / OpenTofu
    status: completed
  - id: role-defaults
    content: Create dot_ansible/roles/iac_tools/defaults/main.yml with per-tool toggles (iac_install_azure_cli / terraform / opentofu)
    status: completed
  - id: chezmoi-prompt
    content: Add installIacTools promptBoolOnce to .chezmoi.toml.tmpl
    status: completed
  - id: playbooks
    content: Register iac_tools role in dot_ansible/playbooks/macos.yml and linux.yml
    status: completed
  - id: run-onchange
    content: Add iac_tools role hashes + optional-tag block to run_onchange_after_20_ansible_roles.sh.tmpl
    status: completed
  - id: dockerfile
    content: Add CHEZMOI_INSTALL_IAC_TOOLS ARG and --promptBool flag to Dockerfile
    status: completed
  - id: docs-iac
    content: Create docs/tools/infrastructure-as-code.md with install/usage notes for Azure CLI, Terraform, OpenTofu
    status: completed
  - id: claudemd
    content: Update CLAUDE.md tags table and Optional profiles list with iac_tools
    status: completed
  - id: readme
    content: Add installIacTools row to README.md Optional Components table
    status: completed
isProject: false
---

## Scope

Install three Infrastructure-as-Code CLIs behind a single `installIacTools` chezmoi prompt (default `false`):

- **Azure CLI** (`az`) — per [Microsoft's install doc](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- **Terraform** (`terraform`) — HashiCorp
- **OpenTofu** (`tofu`) — Linux Foundation fork

Terraform and OpenTofu coexist (different binary names), so installing both is zero-conflict. All three are lightweight CLIs (Terraform/OpenTofu are single static Go binaries; Azure CLI is a Python bundle but ships as an OS package).

## Install matrix

- macOS (Homebrew, always): `brew install azure-cli terraform opentofu` — Terraform requires the `hashicorp/tap`; OpenTofu is a first-class formula (`tofu`). Pattern mirrors the speedtest tap handling in [dot_ansible/roles/networking_tools/tasks/main.yml](dot_ansible/roles/networking_tools/tasks/main.yml) lines 25–40.
- Linux with sudo (Debian/Ubuntu):
  - Azure CLI: Microsoft apt repo (keyring + source list + `apt install azure-cli`).
  - Terraform: HashiCorp apt repo (keyring + source list + `apt install terraform`).
  - OpenTofu: official install script `get.opentofu.org/install-opentofu.sh --install-method deb` (adds repo + installs `tofu`).
- Linux noRoot (`[sudo]` tag skipped):
  - Terraform & OpenTofu: download architecture-matched zip from GitHub releases → extract single binary to `~/.local/bin/` (same pattern as other `~/.local/bin` installs in the networking role).
  - Azure CLI: `uv tool install azure-cli` (consistent with existing `python_uv_tools` role). Gated behind `uv` being present; warn-and-skip otherwise.
- Architecture guard: install only on `x86_64`/`aarch64` (wrap in a `when:` check + `rescue` block, matching the networking role's robustness pattern).

## Files to create

- `dot_ansible/roles/iac_tools/tasks/main.yml` — install tasks (macOS homebrew block, Linux sudo apt block, Linux noRoot user-level block). Follow the `rescue:` + `failed_when: false` pattern from [dot_ansible/roles/networking_tools/tasks/main.yml](dot_ansible/roles/networking_tools/tasks/main.yml).
- `dot_ansible/roles/iac_tools/defaults/main.yml` — toggles per tool:

```yaml
iac_install_azure_cli: true
iac_install_terraform: true
iac_install_opentofu: true
```

This lets users disable any individual tool via `--extra-vars` without changing the single chezmoi prompt.

- `docs/tools/infrastructure-as-code.md` — usage notes: install commands, `az login` / `terraform init` / `tofu init` quick reference, when to prefer OpenTofu vs Terraform, version management caveats, link to Microsoft/HashiCorp/OpenTofu docs.

## Files to edit

- [.chezmoi.toml.tmpl](.chezmoi.toml.tmpl) — add one new prompt above `noRoot`:

```go-template
installIacTools = {{ promptBoolOnce . "installIacTools" "Install Infrastructure-as-Code tools (Azure CLI, Terraform, OpenTofu)" false }}
```

- [dot_ansible/playbooks/macos.yml](dot_ansible/playbooks/macos.yml) and [dot_ansible/playbooks/linux.yml](dot_ansible/playbooks/linux.yml) — register role with tag `iac_tools` (append after `networking_tools`).
- [run_onchange_after_20_ansible_roles.sh.tmpl](run_onchange_after_20_ansible_roles.sh.tmpl):
  - Add role hashes (`iac_tools tasks`, `iac_tools defaults`) to the header comments so changes re-trigger ansible.
  - Add optional-tag block mirroring the `installNetworkingTools` pattern (lines 123–126):

```go-template
{{ $installIacTools := false }}{{ if hasKey . "installIacTools" }}{{ $installIacTools = .installIacTools }}{{ end -}}
{{ if $installIacTools -}}
TAGS="${TAGS},iac_tools"
{{ end -}}
```

- [Dockerfile](Dockerfile) — add `ARG CHEZMOI_INSTALL_IAC_TOOLS=false` and the matching `--promptBool` line (keeps Docker smoke test in sync, per [CLAUDE.md](CLAUDE.md) "Maintaining Dockerfile").
- [CLAUDE.md](CLAUDE.md):
  - "Available Tags" table — add row: `iac_tools` | `Azure CLI, Terraform, OpenTofu`.
  - "Profiles > Tag categories > Optional" — append `iac_tools`.
- [README.md](README.md) "Optional Components" table — add row after `installNetworkingTools`:

```
| `installIacTools` | false | Infrastructure-as-Code CLIs (Azure CLI, Terraform, OpenTofu) |
```

## Validation (no execution in plan mode)

After implementing, the user can run:

```bash
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
```

Per [CLAUDE.md](CLAUDE.md) "Development" section.

## Out of scope

- AWS CLI, gcloud, Pulumi, Ansible-as-IaC (deliberately left for a later iteration; easy to add to the same role).
- Version pinning / mise-managed terraform: HashiCorp/OpenTofu ship static binaries, OS package is fine for this repo's "latest stable" posture.
- Azure CLI extensions (`az extension add ...`) — left to user per project needs.
