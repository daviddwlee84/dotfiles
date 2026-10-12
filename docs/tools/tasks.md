# Tasks — personal task planning

[Tasks (`marcus/tasks`)](https://github.com/marcus/tasks) is a local-first task
manager for personal planning: Inbox, Next actions, Agenda, and Projects. It
stores task records in JSONL files. It complements the agent-oriented issue and
handoff workflow in [`td`](td_sidecar.md); Sidecar provides a UI for both.

## Installed suite

`installCodingAgents=true` installs all three executables through the
`coding_agents` role:

| Command | Purpose |
|---|---|
| `tasks` | CLI for reading and changing your task list. |
| `tasks-tui` | Standalone keyboard and mouse interface. |
| `tasks-api` | Manually started loopback HTTP API. Installation does not start it. |

macOS uses `marcus/tap/tasks`. Linux prefers the same formula through Linuxbrew,
then falls back to the official amd64/arm64 release with checksum verification.
The fallback installs the complete suite in `~/.local/bin`; it needs no Go
toolchain. See the [upstream installation contract](https://github.com/marcus/tasks/blob/v1.17.0/README.md#install).

Native Windows is outside this installer's supported platforms. As checked on
2026-09-25, the [v1.17.0 release targets](https://github.com/marcus/tasks/blob/v1.17.0/.goreleaser.yml)
are macOS and Linux only; use the Linux setup inside WSL on Windows. Native
Windows execution was not tested.

## First-use data location

Tasks requires an explicit store location. On the first install, dotfiles seeds
its plain `key = value` config only when **the config does not exist** and none
of `TASKS_DIR`, `TASKS_FILE`, `TASKS_ARCHIVE`, or `TASKS_MEMORY` has a non-empty
value. This uses the host's XDG paths:

| Surface | XDG location | Default |
|---|---|---|
| Config | `$XDG_CONFIG_HOME/tasks/config` | `~/.config/tasks/config` |
| Data directory | `$XDG_DATA_HOME/tasks` | `~/.local/share/tasks` |

The seed creates these directories and records the **absolute data path** as
`dir = /absolute/path/to/tasks`. This is not TOML: do not quote that path.
It creates no task records or sample data and configures no synchronization.
Relative XDG paths are rejected rather than resolving against the apply directory.

After the first seed, the config and task data belong to you: future applies
preserve existing files, symlinks, and environment overrides. An incomplete
existing setup is reported without replacing it. Inspect the effective paths
with `tasks config --json`; the installer uses that same CLI check.

Each file resolves its **per-file environment variable first, then the matching
`file` / `archive` / `memory` config key**. Missing live/archive paths derive from
the directory selected by `TASKS_DIR`, then config `dir`; missing memory lives
beside the final live file. Thus `TASKS_DIR` does not override explicit per-file
config. A per-file setup needs both live and archive paths. To select another
store, edit the existing config or environment overrides; dotfiles does not
migrate data. See the [v1.17.0 resolver](https://github.com/marcus/tasks/blob/v1.17.0/internal/config/config.go#L89)
and inspect the effective result with `tasks config --json`.

## Start using it

```bash
tasks --version
tasks config --json
tasks-tui
```

From the shell, `tasks inbox`, `tasks next`, and `tasks agenda` show the main
planning views. For example, `tasks capture "Review the release notes"` adds a
task; `tasks help` lists the commands. `tasks-api` is available when you explicitly
want the local API, whose default endpoint is `http://127.0.0.1:4747/api/v1`.
See the [CLI and API overview](https://github.com/marcus/tasks/blob/v1.17.0/README.md#use).

## Tasks in Sidecar

Sidecar has an embedded Tasks tab. Its **Tasks / Beta enablement remains your
choice** in Sidecar's Configuration → Panels & Integrations; installing the suite
does not change Sidecar settings. The standalone commands and embedded UI can
use the same configured Tasks store. This store is separate from td's project
database and does not replace td issues or handoffs.

Sidecar includes its own Tasks UI code, so upgrading the standalone suite does
not upgrade that embedded code; update Sidecar separately. See
[Sidecar's Tasks guide](https://github.com/marcus/sidecar/blob/v1.14.0/website/docs/tasks.md)
and [the three tools' roles](td_sidecar.md).

## Upgrades and optional sync

Homebrew/Linuxbrew installs follow `just upgrade-brew`, or explicitly run
`brew update` followed by `brew upgrade marcus/tap/tasks`. The Linux release
fallback needs an explicit checksum-verified replacement of **all three
binaries**; `chezmoi apply` remains install-only. Follow
[the upgrade procedure](../this_repo/upgrades.md#tasks-suite).

Private Git sync is optional and user-configured; dotfiles does not create a
sync repository, install a merge driver, or start an API service. If wanted,
follow [upstream multi-device sync](https://github.com/marcus/tasks/blob/v1.17.0/docs/multi-device-sync.md).
