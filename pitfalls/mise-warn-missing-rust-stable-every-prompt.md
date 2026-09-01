# `mise WARN  missing: rust@stable` on every shell prompt, forever

**Symptoms** (grep this section):

- Every new shell / every `cd` prints one or both of:
  ```
  mise WARN  missing: rust@stable
  ```
  ```
  mise WARN  missing: go@1.27.0
  ```
  It also leaks into unrelated command output, e.g.:
  ```
  $ chezmoi cd
  mise WARN  missing: rust@stable
  mise WARN  missing: rust@stable
  ```
- `mise ls` shows the configured spec as `(missing)` while a *differently
  named* install of the same tool exists right next to it:
  ```
  go      1.27.0 (missing)  ~/.config/mise/config.toml  latest
  rust    stable (missing)  ~/.config/mise/config.toml  stable
  rust    1.93.0 (symlink)
  ```
- `mise doctor` →
  ```
  2 problems found:
  1. tool core:rust@stable is not installed, install with `mise install`
  2. tool core:go@1.27.0 is not installed, install with `mise install`
  ```
- `~/.cargo/bin/cargo` **exists and works** (`rustc --version` fine), so this
  is *not* the dead-shim trap — `cargo install` succeeds, only the warning is
  wrong.
- macOS only. Linux hosts never show it.
- `chezmoi apply` reports the `Install Rust via mise` task as `ok` and never
  fixes it, run after run.

**First seen**: 2026-09 (Hanrus-Mac-mini, macOS 26.6.2, mise 2026.2.3)
**Affects**: macOS hosts, after commits `581c3ca` (rust pinned to the `stable`
channel) and `34cc271` (Go moved from Homebrew to mise)
**Status**: fixed in repo — `rust_cargo_tools` installs `rust@stable`;
`lazyvim_deps`' config-driven `mise install --yes` now runs on Darwin too

## Symptom

```
$ mise ls --missing
go    1.27.0 (missing)  ~/.config/mise/config.toml  latest
rust  stable (missing)  ~/.config/mise/config.toml  stable

$ ls -la ~/.local/share/mise/installs/rust/
1.93.0 -> /Users/you/.cargo/bin      # real, working install
latest -> ./1.93.0
                                     # ...but no `stable` entry
```

## Root cause

Two independent version-spec drifts, both macOS-only.

**1. `rust@latest` vs `rust = "stable"`.** `dot_config/mise/config.toml.tmpl` is
the SSOT and pins:

```toml
rust = "stable"
```

but `dot_ansible/roles/rust_cargo_tools/tasks/main.yml` installed
`mise install rust@latest`. mise keys its `installs/<tool>/<spec>` directory by
the **spec you asked for**, so `rust@latest` writes `installs/rust/1.93.0` +
`installs/rust/latest` and never creates `installs/rust/stable`. mise then
resolves the config's `stable` → missing.

It never self-heals because the task's `creates:` guard is
`~/.cargo/bin/cargo`, which the `rust@latest` install already satisfied. (That
guard is correct and deliberate — see
[`mise-rust-cargo-shim-dead.md`](mise-rust-cargo-shim-dead.md) — it just cannot
detect a *spec* mismatch.)

**2. Nothing ran `mise install` on macOS at all.** The config-driven
`mise install --yes` task in `dot_ansible/roles/lazyvim_deps/tasks/main.yml`
was gated on `ansible_facts["os_family"] in ["Debian", "RedHat"]`. That was
harmless while every macOS runtime also came from Homebrew — but commit
`34cc271` moved Go **off** the `security_tools` brew install and onto mise
(`go = "latest"`), leaving macOS with a declared runtime and no installer for
it. `mise ls` has reported `go … (missing)` on every macOS host ever since.

## Workaround

```sh
mise install rust@stable go@latest
mise doctor          # -> "No problems found"
```

## Prevention

- `rust_cargo_tools` now installs `rust@stable` (both the mirror-first task and
  the official-server fallback), matching the config SSOT. A comment on the
  task states the coupling explicitly.
- `lazyvim_deps`' mise-binary resolution and `mise install --yes` now include
  `Darwin`, so anything declared in `dot_config/mise/config.toml.tmpl` is
  actually installed on macOS.
- **Rule**: the version spec in any `mise install <tool>@<spec>` inside
  `dot_ansible/` MUST match the spec in `dot_config/mise/config.toml.tmpl`.
  Prefer bare `mise install --yes` (reads the config) over naming a tool.

While fixing this, a second latent bug in the same task surfaced: mise's no-op
output is `mise all tools are installed`, which contains the substring
`install`, so `changed_when: "'install' in mise_install.stdout"` reported
**`changed` on every single run** (on Linux too). The predicate now excludes the
`all tools are installed` line.

## Related

- Sibling pitfall: [`mise-rust-cargo-shim-dead.md`](mise-rust-cargo-shim-dead.md)
  (dead `installs/rust/<ver>` symlinks — same directory, different failure)
- Sibling pitfall:
  [`go-install-gobin-resets-to-mise-toolchain-dir.md`](go-install-gobin-resets-to-mise-toolchain-dir.md)
- SSOT: `dot_config/mise/config.toml.tmpl` `[tools]`
- Commits that introduced the drift: `581c3ca`, `34cc271`
