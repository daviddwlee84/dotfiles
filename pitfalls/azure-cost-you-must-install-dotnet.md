# azure-cost says “You must install .NET” although the SDK is installed

**Symptoms**: `You must install .NET to run this application.`, `.NET location: Not found`, missing `DOTNET_ROOT`, or mise exporting a nonexistent `dotnet-root` directory.
**First seen**: 2026-09
**Affects**: mise-managed .NET global tools; observed on macOS arm64 with mise 2026.9.1, SDK 10.0.203 and azure-cost-cli 0.55.0. The layout issue also applies to Linux.
**Status**: fixed in the managed mise config and dotnet_tools recipe; prevention recorded in the agent contract.

## Symptom

Verbatim relevant excerpt from `azure-cost`:

```text
You must install .NET to run this application.

App: /Users/zhouhanru/.dotnet/tools/azure-cost
Architecture: arm64
App host version: 10.0.7
.NET location: Not found

The following locations were searched:
  Application directory:
    /Users/zhouhanru/.dotnet/tools/.store/azure-cost-cli/0.55.0/azure-cost-cli/0.55.0/tools/net10.0/any/
  Environment variable:
    DOTNET_ROOT_ARM64 = <not set>
    DOTNET_ROOT = <not set>
  Registered location:
    /etc/dotnet/install_location_arm64 = <not set>
  Default location:
    /usr/local/share/dotnet
```

`dotnet --list-sdks` also succeeded through Homebrew, making this look like a
missing dependency despite two SDK installations.

## Root cause

The SDK had been installed: mise's `installs/dotnet/10.0.203` contained SDK
10.0.203 and Microsoft.NETCore.App 10.0.7, compatible with azure-cost's net10.0
runtime requirement. However, mise 2026.9.1 emitted
`DOTNET_ROOT=~/.local/share/mise/dotnet-root`, a directory absent on this host.
The installed layout and mise's default shared-root mode disagreed.

The reported shell had no DOTNET_ROOT; even applying mise's emitted environment
would have pointed at the missing directory. Global tool apphosts do not find
.NET merely by looking up the `dotnet` command on PATH. The old shared shell
module exported DOTNET_ROOT only for legacy `~/.dotnet/dotnet` installations.

Two recipe gaps hid the failure: the SDK task skipped on the mere existence
of `installs/dotnet`, and the tool task checked only executable presence. The
role also used `dotnet@latest` and `mise use -g`, conflicting with the managed
`dotnet = "10"` pin and potentially rewriting the config.

## Workaround

For an intact version-directory installation, this process-local command was
verified to return exit 0 without Azure credentials:

```sh
DOTNET_ROOT="$(mise where dotnet)" azure-cost --help
```

Permanent repair is the updated chezmoi recipe: `dotnet.isolated = true`, a
consistent major spec `10`, and SDK/tool startup checks. Apply the updated
configuration and open a fresh Bash or Zsh shell. For non-interactive use:

```sh
mise exec -- dotnet --list-sdks
mise exec -- dotnet --list-runtimes
mise exec -- azure-cost --help
```

Changing installation mode does not itself move existing SDK files. This fix
preserves the observed version-directory installation. If an SDK is damaged,
inspect its resolved directory and explicitly reinstall that version; apply
must not silently upgrade a healthy installation.

After runtime discovery was fixed, an Azure authentication attempt separately
reported `AADSTS700082: The refresh token has expired due to inactivity.` That
requires a new interactive `az login`; it is not evidence of a runtime failure.
Use `--help` for installation checks: this azure-cost version did not treat
`--version` as an offline version-only request.

## Prevention

- Keep mise's isolated setting explicit and align the role's major version.
- Use `mise install`, never `mise use`, against the managed config.
- Validate the resolved SDK executable so another dotnet on PATH cannot mask it.
- Run global tools through mise for non-interactive checks; keep `smoke_args: [--help]` for azure-cost, including already-installed copies.
- Provision Linux native dependencies explicitly: mise’s SDK installer does not
  install ICU/OpenSSL and the other OS libraries. noRoot requires them preinstalled.
- Test clean installation, existing SDKs, a leftover empty parent directory,
  failed startup, opt-out rendering, and repeat apply without upgrades.

## Verification

- Existing macOS arm64 host: SDK 10.0.203 reused, role reported `changed=0` /
  `failed=0`, and both Bash and Zsh launched `azure-cost --help` successfully.
- Fresh Ubuntu 24.04 arm64 container: removed ICU before the test; the real role
  provisioned native dependencies, SDK 10.0.401 and azure-cost. The second run
  reported `changed=0`; the rendered config hash was unchanged and both shells
  passed the apphost startup check. Reproduce with `tests/smoke/dotnet_install.py`.
- Seven offline regression tests cover empty install parents, existing SDKs,
  broken SDK/tool startup, check mode, the EL7 skip and cross-platform opt-out
  rendering. They also run through `tests/unit/dotnet_tools.bats`.
- Ansible syntax checks, `just docs-build`, secret scans and commit hooks passed.
  macOS Intel, Linux x86_64 and modern RedHat were not tested on real hosts.

## Related

- [mise .NET installation modes](https://mise.jdx.dev/lang/dotnet.html)
- [Microsoft: troubleshoot .NET tool usage](https://learn.microsoft.com/en-us/dotnet/core/tools/troubleshoot-usage-issues)
- [Managed .NET tools](../docs/tools/dotnet-tools.md)
- [Agent runtime invariants](../CLAUDE.md)
