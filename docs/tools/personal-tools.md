# Personal CLI suite

One `installPersonalTools` checkbox manages seven independent tools:

| Formula / repository | Command | Purpose |
| --- | --- | --- |
| dev-cli | `dev` | Repositories, worktrees, tasks and agent runtimes. |
| translate | `translate` | Terminal translation. |
| exp-cli | `exp` | Git-based research workflow and overview. |
| lazychezmoi | `lazychezmoi` | Inspect, edit and apply chezmoi changes. |
| lazyclash | `lazyclash` | Mihomo management and proxy helpers. |
| lazymlflow | `lazymlflow` | MLflow experiments, runs and artifacts. |
| lazypueue | `lazypueue` | Pueue tasks, groups and logs. |

Full bundles (`personal-mac`, `work-mac`, `server-linux`) enable the suite. The
`cloud-vm`, `minimal`, and Docker test defaults disable it. These are CLI installs:
no Mihomo core, MLflow server, Pueue daemon, credentials, or agent skills are
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
The four new tools are not added until an explicit choice. A headless `dotcfg`
partial reconfiguration on an older machine must include this new key once.

## Installation owners

Explicitly enabled macOS machines use [the existing personal Homebrew
tap](https://github.com/daviddwlee84/homebrew-tap). Linux amd64/arm64 machines
install a pinned GitHub release into `~/.local/bin`; downloads are checked
against the exact archive checksum and candidate version before replacement.
These normal installations need neither Go nor sudo. Extra runtimes remains
independent. Unsupported CPU/OS combinations produce an explicit error rather
than silently compiling or installing a new SDK.

`dot_ansible/roles/personal_tools/files/tools.json` owns package names, version
pins, archive names and checksum filenames. Its Python helper is shared by the
Ansible role and upgrades. Apply is install-only; an existing executable is not
silently upgraded. A known legacy source binary on Linux stays source-owned.
Legacy source installs retain their original Go pins, XDG module cache and
missing-Go skip behavior.

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

After publishing a release, update a fresh-install pin only when deliberately
raising the baseline; normal upgrades use the latest stable release for the
existing owner. Update both language inventories, the completion registry and
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
`live_install` dispatch also installs all seven public packages through the real
Ansible role on disposable Linux/macOS runners, verifies receipts and both shell
completions, then checks that a second apply changes nothing. This acceptance
script refuses to run on a workstation or a self-hosted runner.
