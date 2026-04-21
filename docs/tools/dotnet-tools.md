# .NET Tools

Opt-in via `installDotnetTools = true` during `chezmoi init`. This role:

1. Installs the .NET SDK via [mise](https://mise.jdx.dev/) (`mise use -g dotnet@latest`) — same mechanism as `rust_cargo_tools` uses for Rust, so no `brew install dotnet` / Microsoft apt repo / `dotnet-install.sh` dance.
2. Loops over the [`dotnet_tools`](../../dot_ansible/roles/dotnet_tools/defaults/main.yml) list and runs `dotnet tool install --global <pkg>` for each entry. Binaries land in `~/.dotnet/tools`, which is auto-added to `PATH` via [`00_exports.zsh`](../../dot_config/zsh/00_exports.zsh.tmpl) when present.

Shipped tools (default):

| Tool | Binary | Description |
|------|--------|-------------|
| [azure-cost-cli](https://github.com/mivano/azure-cost-cli) | `azure-cost` | Cost analysis / anomaly detection / budgets / CI cost gates for Azure subscriptions |

Add more tools by editing `dot_ansible/roles/dotnet_tools/defaults/main.yml`:

```yaml
dotnet_tools:
  - name: azure-cost-cli
    binary: azure-cost
  - name: dotnet-ef          # EF Core CLI
    binary: dotnet-ef
  - name: PowerShell         # cross-platform PowerShell
    binary: pwsh
```

## Why mise?

- **One SDK manager across the stack.** mise already owns Node.js / Rust / (optionally) Python for this repo. Adding `dotnet` keeps every language runtime in one place under `~/.local/share/mise/installs/`.
- **No sudo / no system package manager.** `mise use -g dotnet@latest` works identically on macOS, Ubuntu with sudo, and Ubuntu `noRoot`. Compare to the previous setup which needed `brew install dotnet`, `packages-microsoft-prod.deb`, or `dotnet-install.sh` depending on platform.
- **Global pin lives in `~/.config/mise/config.toml`.** `mise upgrade dotnet` promotes cleanly and other mise tools keep working on their pinned versions.
- **Shims on PATH.** `~/.local/share/mise/shims/dotnet` resolves `dotnet` automatically once mise is activated in zsh.

## Quick start

```bash
# During chezmoi init
chezmoi init --force   # re-prompt; answer y to installDotnetTools

# Or ad-hoc
ansible-playbook ~/.ansible/playbooks/macos.yml --tags dotnet_tools

# Verify
dotnet --version
azure-cost --help
```

## azure-cost-cli usage

[`azure-cost-cli`](https://github.com/mivano/azure-cost-cli) wraps the Azure Cost Management API. It reuses the same `az login` session so as long as Azure CLI (from the [iac_tools role](./infrastructure-as-code.md)) is authenticated, it "just works".

```bash
# Accumulated cost (current billing month, active subscription)
azure-cost accumulatedCost

# Specific subscription, forced USD
azure-cost accumulatedCost -s <sub-id> --useUSD

# Top 10 costliest resources, markdown output (PR comments / Job Summary)
azure-cost costByResource --top 10 -o markdown

# Daily trends grouped by service
azure-cost dailyCosts --dimension MeterCategory

# Anomaly detection on the last 7 days
azure-cost detectAnomalies --recent-activity-days 7

# Cost by tag (show-back to teams)
azure-cost costByTag --tag cost-center --tag owner

# Budgets + 🟢 OK / 🟡 AT-RISK / 🔴 EXCEEDED status
azure-cost budgets

# CI cost gate: exit 1 if total > $500
azure-cost accumulatedCost -s <sub-id> -o json --fail-if-over 500 > costs.json
```

Authentication notes:

- Uses `ChainedTokenCredential` — picks up `az login` first, then env vars / managed identity
- Account needs **Cost Management Reader** on the target scope
- Not all subscription types expose the Cost Management API (sponsored / CSP-tier). See the [upstream README](https://github.com/mivano/azure-cost-cli#usage) for the quota-id compatibility check.

## Upgrades

```bash
# Upgrade .NET SDK (mise-managed)
mise upgrade dotnet
# or pin a specific channel
mise use -g dotnet@8

# Upgrade a specific global tool
dotnet tool update --global azure-cost-cli

# List installed dotnet global tools
dotnet tool list --global
```

## Troubleshooting

### `dotnet: command not found` after install

The dotnet binary comes in via a mise shim. Ensure `mise activate` ran in your shell:

```bash
# Check shims
ls ~/.local/share/mise/shims/dotnet

# Re-activate mise (should be sourced from your shell config already)
eval "$(mise activate zsh)"
```

### `azure-cost: command not found`

`dotnet tool install --global` puts binaries in `~/.dotnet/tools`. That directory is prepended to `PATH` by [`~/.config/zsh/00_exports.zsh`](../../dot_config/zsh/00_exports.zsh.tmpl) only when it exists, so open a fresh shell after the first install:

```bash
ls ~/.dotnet/tools/          # should show azure-cost
echo $PATH | tr ':' '\n' | rg dotnet
exec zsh                     # pick up the PATH update
```

For bash, add manually:

```bash
echo 'export PATH="$HOME/.dotnet/tools:$PATH"' >> ~/.bashrc
```

### `mise` not found during role run

The role refuses to continue and prints a skip warning when mise isn't installed. mise is part of the bootstrap phase (see [`run_once_before_00_bootstrap.sh.tmpl`](../../run_once_before_00_bootstrap.sh.tmpl)), so the common cause is a partial bootstrap. Re-run:

```bash
curl https://mise.run | sh
chezmoi apply
```

## Related

- [mise dotnet plugin (asdf-dotnet)](https://github.com/mise-plugins/mise-dotnet)
- [dotnet tool install docs](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-tool-install)
- [NuGet search for global tools](https://www.nuget.org/packages?packagetype=dotnettool)
- [docs/tools/infrastructure-as-code.md](./infrastructure-as-code.md) — Azure CLI / Terraform / OpenTofu (separate `installIacTools` opt-in; `az login` here is the auth source for `azure-cost`)
