# `cargo install` fails with "cargo is not a valid shim" after `~/.cargo/bin` is wiped

**Symptoms** (grep this section):

- `chezmoi apply` (or a bare `cargo install …`) fails inside the
  `rust_cargo_tools` role, e.g. on the recon task:
  ```
  TASK · [rust_cargo_tools : Install recon (Claude Code tmux dashboard) via cargo install --git]
  mise ERROR cargo is not a valid shim. This likely means you uninstalled a tool
  and the shim does not point to anything. Run `mise use <TOOL>` to reinstall the tool.
  ```
  or, depending on which cwd / context:
  ```
  mise ERROR cargo is a mise bin however it is not currently active. Use `mise use` to activate it
  ```
- `which cargo` → `cargo not found`; `~/.cargo/bin/cargo` does not exist.
- `mise ls rust` shows the pinned version as **`(missing)`** even though
  `~/.local/share/mise/installs/rust/` exists and is full of symlinks:
  ```
  $ mise ls rust
  rust  1.95.0 (missing)  ~/.config/mise/config.toml  latest
  $ ls -la ~/.local/share/mise/installs/rust
  1.93.0 -> /Users/you/.cargo/bin      ← target deleted; dead symlink
  latest -> ./1.93.0
  ```
- The ansible task `Install Rust via mise` reports **`ok` in ~0.2s** (it was
  skipped by its `creates:` guard, not actually run).
- **Cascading variant** (observed 2026-06-10 on `ta-stg`, Ubuntu 22.04): every
  `mise exec -- npm install -g …` task (coding_agents, js_cli_tools) fails with
  the same rust error before npm even runs — `mise exec` auto-installs ALL
  missing config tools first, so one broken rust mirror takes down unrelated
  npm installs and the `js_cli_tools` task (the only non-`ignore_errors` one)
  fails the whole play:
  ```
  mise rust@1.96.0     [1/3] install
  error: could not download nonexistent rust version `1.96.0-x86_64-unknown-linux-gnu`:
  … 'https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/rust-1.96.0-….tar.gz.sha256'
  … http request returned an unsuccessful status code: 404
  ```
  Here TUNA's channel manifest already named 1.96.0 but the tarballs were not
  yet synced (mirror lag, the inverse of the GC case). Also note: the
  `creates: ~/.cargo/bin/cargo` guard does NOT help in this state — rustup's
  proxy shims exist in `~/.cargo/bin` even though no toolchain is installed
  ("rustup could not choose a version of cargo to run").

## Root cause — two independent traps that compound

1. **Dead-symlink + coarse `creates:` guard.** mise's `rust` backend is rustup,
   which installs the toolchain into `~/.cargo/bin` and makes
   `~/.local/share/mise/installs/rust/<ver>` a **symlink to `~/.cargo/bin`**. If
   `~/.cargo/bin` is later deleted (manual cleanup, disk reset, etc.), the mise
   `installs/rust` dir lingers full of dead symlinks. A guard of
   `creates: ~/.local/share/mise/installs/rust` then sees the dir, **skips the
   reinstall forever**, and the `cargo` shim resolves to nothing.

2. **Mirror manifest GC (GFW).** When `RUSTUP_DIST_SERVER` points at a mirror
   (this repo's users set the TUNA mirror in `dot_config/mise/config.toml.tmpl`
   / shell env), and the mise config pins `rust = "latest"`, `mise install
   rust@latest` can fail because the mirror has GC'd / not-yet-synced the newest
   manifest:
   ```
   info: syncing channel updates for 1.95.0-aarch64-apple-darwin
   error: the server unexpectedly provided an obsolete version of the distribution manifest
   mise ERROR Failed to install core:rust@latest
   ```
   So even once the guard re-triggers, the install itself fails on the mirror.

## Fix (shipped in `dot_ansible/roles/rust_cargo_tools/tasks/main.yml` + `lazyvim_deps`)

- Guard the mise rust install on **`creates: ~/.cargo/bin/cargo`** (the real
  backing binary), not the `installs/rust` dir — self-heals the dead-symlink
  state. Consistent with the cargo-tools task and the EL7 rustup-init fallback.
- **Try the configured mirror first, then fall back to the official server**
  (`RUSTUP_DIST_SERVER=https://static.rust-lang.org`,
  `RUSTUP_UPDATE_ROOT=https://static.rust-lang.org/rustup`) when the first
  attempt returns non-zero — generalizes the CentOS-7 workaround to all
  platforms. crates.io stays on the user's `~/.cargo/config.toml` mirror so
  dependency builds keep their speed.
- **`lazyvim_deps` retries `mise install --yes` against the official server**
  when the first (mirrored) run exits non-zero. lazyvim_deps runs *before*
  coding_agents / js_cli_tools in every profile's tag order, so repairing rust
  there keeps the later `mise exec -- npm …` tasks from tripping over the
  auto-install cascade (the `mise install` path has no `creates:` guard, so it
  also self-heals the proxy-shims-but-no-toolchain state).

## Manual repair (one machine, without a full apply)

```sh
# Force the canonical rustup server just for the toolchain manifest:
RUSTUP_DIST_SERVER=https://static.rust-lang.org \
RUSTUP_UPDATE_ROOT=https://static.rust-lang.org/rustup \
  mise install rust@latest
mise reshim
mise exec -- cargo --version    # should print the pinned version, e.g. 1.95.0
```

Observed 2026-05-20 on `Da-Weis-Mac-mini` (macOS arm64): TUNA's `1.95.0` manifest
was obsolete while the toolchain itself was already synced — only the official
server returned a valid manifest. `~/.cargo/bin` had been wiped, leaving mise's
`installs/rust` symlinks dangling.
