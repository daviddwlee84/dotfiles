# .NET Tools

Opt-in via `installDotnetTools = true` during `chezmoi init`. This role:

1. Installs the .NET 10 SDK via [mise](https://mise.jdx.dev/lang/dotnet.html) with `mise install --yes dotnet@10`. The managed config explicitly uses `dotnet.isolated = true`, retaining version-specific SDK directories and matching `DOTNET_ROOT`.
2. Verifies the resolved SDK can run, then installs missing global tools through `mise exec dotnet@10 -- dotnet tool install --global <pkg>`. Executables live in `~/.dotnet/tools`; the shared [shell exports](../../dot_config/shell/00_exports.sh.tmpl) add it to PATH for both Bash and Zsh.
3. Runs each configured offline startup check, including `azure-cost --help`, even for already-installed tools. A failed runtime or tool check fails the role. Apply installs missing tools; upgrades remain explicit.

Shipped tools (default):

| Tool | Binary | Description |
|------|--------|-------------|
| [azure-cost-cli](https://github.com/mivano/azure-cost-cli) | `azure-cost` | Cost analysis / anomaly detection / budgets / CI cost gates for Azure subscriptions |

Add more tools by editing `dot_ansible/roles/dotnet_tools/defaults/main.yml`:

```yaml
dotnet_tools:
  - name: azure-cost-cli
    binary: azure-cost
    smoke_args: [--help]       # optional argv list; must not require credentials
  - name: dotnet-ef          # EF Core CLI
    binary: dotnet-ef
  - name: PowerShell         # cross-platform PowerShell
    binary: pwsh
```

## Why mise?

- **One SDK manager across the stack.** mise already owns Node.js / Rust / (optionally) Python for this repo. Adding `dotnet` keeps every language runtime in one place under `~/.local/share/mise/installs/`.
- **User-local SDK.** `mise install --yes dotnet@10` installs the SDK without sudo or a Microsoft package repository. On Linux the role installs native ICU/OpenSSL/C++/Kerberos/zlib dependencies through apt/dnf (`state: present`, tagged `sudo`). Debian uses `libicu-dev` and `libssl-dev` to select the distro’s runtime ABI without hardcoding versioned package names. `noRoot` skips these system packages and requires them to be preinstalled; the startup check reports missing libraries.
- **Global pin lives in `~/.config/mise/config.toml`.** `mise upgrade dotnet` explicitly upgrades within the configured major. Ansible never uses `mise use`, which would rewrite this chezmoi-owned config.
- **Runtime discovery.** mise activation in both Bash and Zsh exports `DOTNET_ROOT` as well as adding the SDK to PATH. Non-interactive scripts should use `mise exec -- azure-cost …`; a dotnet shim alone does not tell a global tool apphost where its runtime lives.

## Quick start

```bash
# During chezmoi init
chezmoi init --force   # re-prompt; answer y to installDotnetTools

# After the managed mise config has been deployed, re-run just this role
ansible-playbook ~/.ansible/playbooks/macos.yml --tags dotnet_tools

# Verify without Azure credentials
mise exec -- dotnet --list-sdks
mise exec -- azure-cost --help
# Open a new Bash/Zsh shell, then also check bare azure-cost --help
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
# Change major only by updating both managed config and role defaults.

# Upgrade a specific global tool
mise exec -- dotnet tool update --global azure-cost-cli

# List installed dotnet global tools
mise exec -- dotnet tool list --global
```

## Troubleshooting

### `You must install .NET to run this application.`

An installed SDK and a working `dotnet --version` are not enough: standalone
global tool apphosts need to discover the compatible runtime. A Homebrew dotnet
on PATH can mask a broken mise SDK environment.

```bash
mise where dotnet
mise env --shell bash | rg DOTNET
mise exec -- dotnet --list-runtimes
mise exec -- azure-cost --help
```

The managed `dotnet.isolated = true` setting keeps new installations and older
version-directory installs consistent. A missing `~/.local/share/mise/dotnet-root`
with an SDK still under `installs/dotnet/<version>` indicates the shared/isolated
layout mismatch. Apply the updated config, then open a new shell. For a temporary
check of an intact version-directory installation:

```bash
DOTNET_ROOT="$(mise where dotnet)" azure-cost --help
```

See the [symptom and recovery record](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/azure-cost-you-must-install-dotnet.md).
If the SDK itself cannot run, the role fails rather than silently upgrading it;
inspect the resolved installation and explicitly reinstall the affected SDK.

### `dotnet` or `azure-cost`: command not found

Complete the opted-in installation, then open a fresh Bash or Zsh shell so mise
activation and the shared PATH module see the newly installed directories.
Both shells are configured automatically; do not append duplicate PATH edits
to managed rc files. For non-interactive commands use `mise exec -- …`.

### `mise` not found during role run

The role fails with a bootstrap hint when mise isn't installed. mise is part of the bootstrap phase (see [`run_once_before_00_bootstrap.sh.tmpl`](../../run_once_before_00_bootstrap.sh.tmpl)), so the common cause is a partial bootstrap. Re-run:

```bash
curl https://mise.run | sh
chezmoi apply
```

## Recipe validation

Offline regression tests execute the real role with a fake SDK and check
opt-in/opt-out template rendering:

```sh
python3 -m unittest discover -s tests/unit -p test_dotnet_tools.py -v
```

For a real fresh-install smoke, use a disposable Ubuntu 24.04 container with
mise, chezmoi, ansible-core, Bash/Zsh, CA certificates, and root/sudo access:

```sh
python3 tests/smoke/dotnet_install.py
```

The smoke creates its own HOME, applies the managed templates with chezmoi,
installs through the actual role, repeats the role to check idempotency, and
starts azure-cost from both shells. It downloads the SDK and NuGet package;
it does not need or copy Azure credentials.

## Related

- [mise .NET core backend](https://mise.jdx.dev/lang/dotnet.html)
- [dotnet tool install docs](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-tool-install)
- [NuGet search for global tools](https://www.nuget.org/packages?packagetype=dotnettool)
- [docs/tools/infrastructure-as-code.md](./infrastructure-as-code.md) — Azure CLI / Terraform / OpenTofu (separate `installIacTools` opt-in; `az login` here is the auth source for `azure-cost`)
