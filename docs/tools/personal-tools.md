# Personal CLI suite

One `installPersonalTools` checkbox manages thirteen independent tools with binary packages:

| Repository | Command | Purpose |
| --- | --- | --- |
| dev-cli | `dev` | Repositories, worktrees, tasks and agent runtimes. |
| translate | `translate` | Terminal translation. |
| exp-cli | `exp` | Git-based research workflow and overview. |
| lazychezmoi | `lazychezmoi` | Inspect, edit and apply chezmoi changes. |
| lazyclash | `lazyclash` | Mihomo management and proxy helpers. |
| lazymlflow | `lazymlflow` | MLflow experiments, runs and artifacts. |
| lazypueue | `lazypueue` | Pueue tasks, groups and logs. |
| lazyansible | `lazyansible` | Personal fork: Ansible inventory, playbooks and reviewed execution. |
| lazycrontab | `lazycrontab` | Local/SSH cron inspection, schedule editing and previews. |
| lazyfind | `lazyfind` | Local/SSH file and text search, previews and result actions. |
| lazypkg | `lazypkg` | Software inventory, PATH diagnostics and reviewed package operations. |
| lazymermaid | `lazymermaid` | Repository Mermaid workbench with optional Neovim and local renderers. |
| lazyset | `lazyset` | Local/SSH TUI catalog and retained terminal sessions. |

Full bundles (`personal-mac`, `work-mac`, `server-linux`) enable the suite. The
`cloud-vm`, `minimal`, and Docker test defaults disable it. These are CLI installs:
no Mihomo core, MLflow server, Pueue daemon, cron jobs, mpm backend, credentials, or agent skills are
provisioned implicitly. Existing dotfiles-owned commands such as `fleet` and
`mlf` retain their current distribution.

## Enable or disable

```sh
dotcfg --set installPersonalTools=true --yes --no-apply
# Inspect the resulting configuration, then run your normal apply workflow.
```

Use `false` to stop managed installation. Disabling does not uninstall existing
binaries, stop services, or disable capability-based runtime integrations.
The suite never installs itself on first invocation. Shell startup, completion,
pickers, and background service checks only use already-installed tools.

Older machines without this key retain the previous selection: macOS still
installs dev/translate with Brew; Linux dev/translate and both platforms'
lazyclash use legacy Go installs only when `installExtraRuntimes` is enabled.
All other suite members require an explicit choice. A headless `dotcfg`
partial reconfiguration on an older machine must include this new key once.

## Installation owners

Explicitly enabled macOS machines use [the existing personal Homebrew
tap](https://github.com/daviddwlee84/homebrew-tap). Linux amd64/arm64 machines
install a pinned GitHub release into `~/.local/bin`; downloads are checked
against the exact archive checksum and candidate version before replacement.
These binary installations need neither Go nor sudo. Extra runtimes remains
independent. Unsupported CPU/OS combinations produce an explicit error rather
than silently compiling or installing a new SDK.

`dot_ansible/roles/personal_tools/files/tools.json` owns package names, version
pins, archive names and checksum filenames. Its Python helper is shared by the
Ansible role and upgrades. Apply is install-only; an existing executable is not
silently upgraded. A known legacy source binary on Linux stays source-owned.
Legacy source installs use the registry’s explicit `legacy_pin`, retaining the
XDG module cache and missing-Go skip behavior. The source-packaging baseline
raises both release and existing legacy pins; it does not upgrade installed
binaries during apply.

Receipts live under `${XDG_DATA_HOME:-~/.local/share}/dotfiles/personal-tools/`.
They record install origin; probe the actual binary for its current version,
since a native updater may have advanced it. An unknown same-name executable is
preserved and reported as unmanaged. Package-manager-owned files stay with that
manager.

When moving a verified legacy `~/.local/bin` Go copy to Brew on macOS, the helper
first installs and verifies the Brew binary, then backs up the old copy under
the receipt directory's `backups/`. A concurrently edited executable or an
unknown local build is not removed. Inspect the receipt before manually restoring
a backup; a second active PATH copy can shadow the intended owner.

## New lazy tools and runtime prerequisites

The September 2026 additions all use the same binary installation channels as
the existing suite. Go is optional for source builds, not a requirement for
chezmoi installation. New-install pins:

| Tool | Binary baseline | Runtime prerequisites |
| --- | --- | --- |
| [lazyansible](https://github.com/daviddwlee84/lazyansible/releases/tag/v0.1.0) | `v0.1.0` | Existing Ansible; optional uv-based runtime setup remains a separate command. |
| [lazycrontab](https://github.com/daviddwlee84/lazycrontab/releases/tag/v0.1.2) | `v0.1.2` | Target-side cron tools and SSH for remote hosts; apply creates no jobs. |
| [lazyfind](https://github.com/daviddwlee84/lazyfind/releases/tag/v0.1.2) | `v0.1.2` | fd/rg on the searched host; rga/converters and zoxide are optional. |
| [lazypkg](https://github.com/daviddwlee84/lazypkg/releases/tag/v0.1.3) | `v0.1.3` | mpm 8.0.1 and relevant native managers; use lazypkg's reviewed Setup if needed. |
| [lazymermaid](https://github.com/daviddwlee84/lazymermaid/releases/tag/v0.1.0) | `v0.1.0` | Explorer/handbook work alone; Neovim, termaid and Node/Mermaid runtime are optional capabilities. |
| [lazyset](https://github.com/daviddwlee84/lazyset/releases/tag/v0.1.1) | `v0.1.1` | Independently installed child TUIs; system OpenSSH for remote hosts. |

lazyansible is the personal fork, not the upstream kocierik package. A same-name
executable from the upstream fork is preserved as unmanaged; resolve its owner
before switching. None of these tools automatically installs its backends or
registers real hosts during dotfiles apply. Runtime setup and package operations
remain explicit product actions.

The new tools expose `upgrade --check` / `upgrade --yes` for verified Homebrew
ownership; lazypkg uses `self upgrade` because `lazypkg upgrade PACKAGE` updates
a managed package. `lazyansible runtime upgrade` updates Ansible, separately from
lazyansible itself. For the full installed suite, use `just upgrade-personal`;
it also owns verified Linux binary updates. Existing source copies stay with
their recognized source owner; publication of binaries alone never overwrites
an unknown local build or changes installed versions during apply.

The release matrix covers macOS/Linux amd64/arm64. Windows dotfiles has its own
registry; these six additions are not automatically Windows installations.

## Explicit upgrades

```sh
just upgrade-personal
scripts/upgrade_tools.sh personal --dry-run
scripts/generate_completions.sh --tool lazymlflow --force
```

Personal upgrades operate on the selected **and installed** set. They preserve
Brew, managed release, or identified Go source ownership; missing or unknown
tools are skipped. Go-source upgrades need an existing Go toolchain and never
bootstrap one. Successful changes refresh that tool's Bash/Zsh completions.
Checksum, download, or candidate-version failure preserves the old binary;
there is no network-error fallback to source compilation.

`just upgrade-go` now covers non-personal Go tools (currently Linux gopls).
Personal formulas are outside Brewfile, so `upgrade-brew`'s `brew bundle` step
cannot recreate a deleted personal CLI. Ordinary `brew upgrade` can still update
installed formulas: the installation checkbox is not a version freeze.

## Release and tap maintenance

Each application owns its binary releases. The tap centrally reads stable public
releases on a schedule or manual dispatch, verifies the complete archive set and
checksums, and updates only changed formulas. It retains the previous formula
when a release is incomplete or inconsistent. Formula publication does not
require distributing a tap-write token to every application repository.

Binary packages contain runtime files only. The source-packaging releases also
provide checksummed source archives and exclude development transcripts/plans
from Go module downloads while preserving build inputs. These exclusions do not
reduce a full Git clone or remove published history.

After publishing a release, update a fresh-install pin only when deliberately
raising the baseline; binary upgrades use the latest stable release for the
existing owner. Legacy source upgrades use Go’s `@latest` version selection. Update both language inventories, the completion registry and
the chezmoi agent skill when adding/removing a suite member.

## Verification

Fixtures cover selection, legacy migration, disabled and missing tools, owner
preservation, candidate validation, atomic replacement/rollback, and real Ansible
check mode without executing a live installer:

```sh
bats tests/unit/personal_tools.bats tests/unit/lazyclash_setup.bats
just gen-prompts --check
just ansible-syntax-check
just docs-build
```

The `Personal tools` GitHub workflow runs the fixtures on changes. Its optional
`live_install` dispatch installs all thirteen binary packages through the real Ansible role on disposable Linux/macOS runners, verifies receipts and both shell
completions, then checks that a second apply changes nothing. This acceptance
script refuses to run on a workstation or a self-hosted runner.
