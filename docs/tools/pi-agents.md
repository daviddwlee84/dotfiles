# Pi / OMP harness combos (`pia`)

`installCodingAgents=true` installs the two agent engines and deploys the
Git-managed [`pi-agents`](https://github.com/daviddwlee84/pi-agents) combo
manager. The three commands have separate owners so upgrades stay predictable:

The combo repository is private. On a new machine, ensure GitHub HTTPS
credentials are available before `chezmoi apply` (for example, `gh auth login`
then `gh auth setup-git`).

| Command | Installed by | Location | Upgrade path |
|---|---|---|---|
| `pi` | npm package `@earendil-works/pi-coding-agent` | `~/.local/bin/pi` | `just upgrade-agents` |
| `omp` | official prebuilt installer | `~/.local/bin/omp` | `just upgrade-agents` |
| `pia` | chezmoi git external | `~/.local/share/pi-agents/bin/pia` | `just upgrade-externals` |

The Pi package is installed with `--ignore-scripts` into a stable
`~/.local` npm prefix. This keeps the command available when mise upgrades
Node. Setup transactionally installs and verifies the canonical copy first,
then removes deprecated `@mariozechner/pi-coding-agent` and duplicate
maintained Pi packages from npm's active runtime prefix. If installation or
verification fails, the previous `pi` command is restored and cleanup does not
start.

OMP is forced onto its prebuilt-binary channel; otherwise its installer
switches to Bun whenever Bun exists and can fail on an older Bun before trying
the standalone build. Setup first detects package-managed copies without
changing them, transactionally installs and verifies the standalone binary,
then removes only the exact `@oh-my-pi/pi-coding-agent` package from the
stable/active npm globals and documented Bun global directory, including
custom `BUN_INSTALL_GLOBAL_DIR` / `BUN_INSTALL_BIN` locations. A failed
download restores the previous `omp` command and leaves those packages intact.

## First use

Open a new shell after `chezmoi apply`, then verify and select a combo:

```sh
pi --version
omp --version
pia doctor
pia list --tree
pia use pi/base
pia run
```

Shell completion is generated during `chezmoi apply`; for example,
`pia use <Tab>` lists combo ids from the active source root without launching
the TypeScript CLI again for every completion attempt.

`pia use` writes only the current selection. Do not export `PIA_COMBO` globally:
that environment variable has higher precedence and would make `pia use` appear
not to work.

## Ownership boundary

- Chezmoi owns the external checkout and PATH wiring.
- Git in the `pi-agents` repository owns the CLI source and combo definitions.
- `pia` owns private runtime configuration, sessions, and handoff artifacts
  under XDG state/config locations.
- Pi and OMP own their authentication. Credentials never belong in either
  dotfiles or the external checkout.

Treat `~/.local/share/pi-agents` as a deployment mirror. Author or derive combos
in a normal development clone, commit and push them, then run
`just upgrade-externals`. No `npm install`, `npm link`, or generated `dist/`
directory is required for `pia`.

The shared `08_pi_agents.sh` fragment loads after mise and Bun setup. It
re-prepends `~/.local/bin` when managed Pi/OMP binaries exist, then prepends the
external `pia` bin directory. Upgrade commands also invoke the exact canonical
paths rather than whichever same-named command happens to appear first on PATH.

## Compatibility

Pi and `pia` require Node 22.19 or newer. The OMP prebuilt installer supports
macOS and Linux on x64/arm64. The engine-install tasks skip the known-
incompatible armv7 Node 20 path and EL7 baseline. The external checkout may
still refresh there, but `pia doctor` reports the incompatible Node runtime
until the host is upgraded.

OMP's and `pia`'s zsh/bash completion files are regenerated automatically
during apply. OMP tracks its binary mtime; `pia` tracks the external checkout's
Git revision stamp because its launcher can remain byte-identical across source
updates. Authentication and a first real agent request remain manual smoke
tests because they require provider credentials.
