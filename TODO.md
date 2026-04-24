# TODO

Long-term backlog for the dotfiles repository. See [`AGENTS.md`](AGENTS.md) for
maintenance contract and [`README.md`](README.md) for current architecture.

> **For agents**: when the user surfaces an idea explicitly **not** being implemented
> this session (signals: "maybe later", "nice to have", "if I'm interested",
> "工程量太大需要再評估", "先記下來"), add it here with priority + effort tags.
> Do not create new `ROADMAP.md` / `IDEAS.md` / `BACKLOG.md` files — `TODO.md` is
> the single backlog index. Long-form research goes in [`backlog/<slug>.md`](backlog/).

## How to read this

Each item carries two tags:

- **Priority**: `P1` (next likely batch) · `P2` (worth doing) · `P3` (someday) · `P?` (needs evaluation first — spike before committing)
- **Effort**: `S` (< 1h) · `M` (half day) · `L` (multi-day) · `XL` (architectural, design doc first)

A trailing `→ [research](backlog/<slug>.md)` link means the item has accompanying
investigation, design notes, or paused troubleshooting — read that first before
re-investigating. Items without a link are simple enough to act on directly.

When implementing an item, move it to the `## Done` section in the same commit
with a one-line summary of what shipped.

---

## P1 — Likely next batch

- [ ] **[S] Starship status-aware modules** — enable `status` / `cmd_duration` / `shlvl` / `container` in `dot_config/starship.toml`. Pure additive, no risk. → [research](backlog/starship-context-modules.md)
- [ ] **[S] tmux2k bandwidth bug** — drop `bandwidth` from `@tmux2k-right-plugins` in `dot_config/tmux/theme.tmux2k.conf` (uint64 underflow already documented in the file's own comment). → [research](backlog/tmux2k-tuning.md)
- [ ] **[S] tmux2k theme alignment** — switch `@tmux2k-theme` from `onedark` to `catppuccin` so the tmux2k layout matches Ghostty/Neovim's colour story. → [research](backlog/tmux2k-tuning.md)
- [ ] **[M] Fix Claude Code hook on Ubuntu (headless)** — `Stop hook error: ... org.freedesktop.Notifications was not provided by any .service files`. Headless servers have no notification daemon; need either fallback in the hook or `libnotify` + lightweight daemon.

## P2 — Worth doing, no rush

- [ ] **[M] miniforge/conda ansible role** — `dot_config/zsh/tools/04_conda_mamba.zsh` already lazy-loads if conda is present, but no role installs it. Decide: ansible role vs delegate to `mise`/`brew install --cask miniforge`.
- [ ] **[M] nvm ansible role** — `02_legacy_tools.zsh` wires PATH + provides `load-nvm` alias, but no role installs nvm itself. May be obviated by mise consolidation (see P? below).
- [ ] **[S] bun / pnpm / go install via ansible** — PATH wiring already in `02_legacy_tools.zsh`; just need install steps (likely additions to `js_cli_tools` and a new `go_tools` role, or fold into `devtools`).
- [ ] **[M] Pueue config via chezmoi** — manage `~/.config/pueue/pueue.yml` and decide macOS strategy (`PUEUE_CONFIG_PATH` env var vs path sync to `~/Library/Application Support/pueue/pueue.yml`).
- [ ] **[L] secrets.zsh encryption with age** — currently plaintext + chezmoi-ignored. Age-encrypted version could live in the source tree. Needs key distribution plan across machines.
- [ ] **[M] aicapture: non-tmux output capture (Tier 2)** — Tier 1 (`aifix-stdin` / `aifix-run` / `aifix-rerun`) shipped; transparent preexec/precmd tee redirect would remove the "remember to prefix" friction for non-tmux daily users. Tier 3 (script(1) or PTY proxy) explicitly rejected. → [research](backlog/ai-capture-non-tmux-output.md)
- [ ] **[S] mkdocs anchor drift cleanup** — first deploy uses `validation.links.anchors: info` so ~20 stale section-anchor links in existing docs don't fail CI strict. Batch-fix them, then raise back to `warn` in `mkdocs.yml`. → [research](backlog/mkdocs-anchor-drift.md)

## P3 — Someday / nice to have

- [ ] **[S] TA-Lib path management** — currently in `secrets.zsh` as machine-specific. Could move to a `99_local_*.zsh` create-only stub like the proxy pattern in `dot_config/zsh/99_local_proxy.zsh`.
- [ ] **[S] Try / Toolkami custom tool aliases** — currently in `secrets.zsh`. Same `99_local_*.zsh` pattern as TA-Lib above; group together.
- [ ] **[M] Super Productivity Linux install** — currently macOS-only via `dot_config/homebrew/Brewfile.darwin.tmpl:83` cask. For fleet parity (`fleet-apply` against Ubuntu desktops) need either AppImage in a new ansible task or snap. Defer until first Linux desktop host actually wants it. The `tv super-productivity` channel + REST API integration ([docs/tools/super-productivity.md](docs/tools/super-productivity.md)) are cross-platform; only the desktop install path is missing.
- [ ] **[?/L] `spctl` + `super-productivity-mcp`** — wrap SP's local REST API ([docs/tools/super-productivity.md](docs/tools/super-productivity.md)) as a CLI for shell automation and an MCP server for coding agents. The TV channel (v0.1) intentionally exercises every read route first to validate behaviour. Phase 2 (mutations: start/stop/complete/archive) lands as Alt-key bindings on the same channel before extracting into a separate package. Open question: TypeScript monorepo vs. plain Python `uv` script — the latter matches the rest of this repo's `scripts/` style.
- [ ] **[M] `js_cli_tools` / `coding_agents` ansible: gate on minimum Node version** — both roles call `npm install --global` against system npm without checking the version. On Ubuntu 22.04 jammy hosts (e.g. `ts_nas`) the apt-installed `/usr/bin/npm` is v8.5.1 / Node v12.22.9, which fails `EBADENGINE` on modern packages (`@openai/codex` requires Node ≥18) and `EACCES` on `/usr/local/lib/node_modules` for non-root users. Fix path A in [pitfalls/ansible-js-cli-tools-old-system-node.md](pitfalls/ansible-js-cli-tools-old-system-node.md) covers the role-side patch (`is version('v18.0.0', '<')` check that forces mise fallback).
- [ ] **[M] fleet-apply long-run sudo session expiry** — `jingle207` ran for 7m50s under `just fleet-apply` and failed at task `Ensure xz is available for worktrunk extraction` with `sudo: a password is required` even though the run started with `CHEZMOI_SUDO_PASSWORD_FILE` populated. Either (a) the sudo password file gets cleaned up by the wrapper's `_cleanup` trap before late tasks need it, or (b) Linux sudo `timestamp_timeout` (default 5m for many distros, 15m for some) expires mid-run and `sudo -S` doesn't re-prompt automatically. Investigation needed: instrument `scripts/lib/sudo_shared.sh` to refresh the cache periodically, or have `sudo_session_init` re-validate via `sudo -S -v -p ''` before each privileged task. See AGENTS.md → "Sudo session is shared across all run-scripts" for the existing contract.
- [ ] **[S] fleet-apply `--serial` mode misses drift downgrade** — `_classify_drift()` in `scripts/fleet_apply.py` correctly downgrades `chezmoi: <path>: could not open a new TTY: open /dev/tty:` to drift in parallel mode, but `just fleet-apply-one HOST` (which uses `--serial`) reports `rc=1` for the same condition instead of `drift`. Verified on `hanru_mac` 2026-04-24: only diff was `~/.config/worktrunk` directory mode (40700 → 40755), and serial-mode reported failed; identical condition under parallel was correctly classified. Likely a code path that bypasses `_classify_drift` when `--serial` is passed.

## P? — Needs evaluation before committing

- [ ] **[?/M] tmux window status indicators — option C (hook-based per-pane state)** — option A (built-in `monitor-activity`/`bell` flags) shipped 2026-04 in `dot_config/tmux/common.conf`. Option C (semantic running/idle/error glyphs driven by Claude hooks + OpenCode plugin writing per-pane state files) is fully scoped but deferred until option A's `#` flag proves insufficient or another feature also needs the per-pane state file. Claude side is additive to `dot_claude/hooks/executable_notify.sh.tmpl` (low risk); OpenCode side is a new JS plugin (new surface, more risk). → [research](backlog/tmux-window-status-indicators.md)
- [ ] **[?/S] specstory: enable opencode auto-wrap when upstream lands** — `_sesh_wrap_agent` in `dot_config/zsh/tools/22_sesh.zsh` currently passes `opencode` through raw because specstory doesn't support it as a provider. Add to the case statement (one-line change) once `specstoryai/getspecstory#156` merges + ships. → [research](backlog/specstory-opencode-support.md)
- [ ] **[?/L] Use mise to manage most runtime versions** — already used for Node (Neovim) and Rust (Cargo) per `README.md`. Question: extend to python/go/ruby and retire ad-hoc PATH wiring + nvm? Trade-off: another layer vs unified version pinning. Spike: pick one runtime currently outside mise (go?), try alongside current setup for two weeks.
- [ ] **[?/L] Optimize zsh & tmux startup time** — needs profiling first (`zprof`, `time zsh -i -c exit`). Current state: conda/nvm are lazy-loaded already, so low-hanging fruit may be gone. Don't optimize blind.
- [ ] **[?/XL] CUDA / ML toolchain ansible role** — driver/cudnn/nccl version matrix is large; only relevant on Linux ML hosts. Defer until there's a concrete host that needs it. Likely belongs behind a new `ml_linux` profile.
- [ ] **[?/XL] SLURM client config** — same shape as CUDA above: host-specific, likely a `dot_slurm/` template gated by profile. No machine currently needs it.
- [ ] **[?/XL] Raycast config sync for non-Pro users** — git-tracked, redacted cross-machine sync for hotkeys / quicklinks / snippets / aliases / extensions. Full scaffold was built (key-name redactor, extensions-manifest walker, secrets.env.example emitter, chezmoi `syncRaycast` prompt with 3-file parity, `just raycast-*` recipes) but paused: Raycast's `.rayconfig` export is AES-encrypted with a non-public KDF that mixes in keychain-bound material — we brute-forced 150+ scheme combinations (PBKDF2/scrypt/SHA*/EVP_BytesToKey) against password `12345678` with zero plausible decodes, and Raycast forces a non-empty password field so even the empty-password bypass is closed. Cheapest revival spike: inspect the separate `Export Quicklinks` / `Export Snippets` commands for a plaintext format. Adjacent pitfall (`raycast-library-files-not-portable-across-machines.md`) stays live. → [research](backlog/raycast-sync-non-pro.md)

---

## Done (recent, kept for context — older items pruned)

- ✅ **`.chezmoiscripts/{global,repo}/` layout** — six `run_onchange_after_*.sh.tmpl` scripts moved out of repo root into a 2-bucket nested layout (Option A). `repo_` infix dropped from `45_bootstrap_skills` (scope now encoded in directory). Cross-refs updated in AGENTS/CLAUDE/docs/ignore files. Layout doc: [docs/this_repo/chezmoiscripts-layout.md](docs/this_repo/chezmoiscripts-layout.md). Decision log: [backlog/chezmoiscripts-namespace-refactor.md](backlog/chezmoiscripts-namespace-refactor.md). One-time cost: chezmoi re-runs each script once on every machine after the path change.

- ✅ **tmux built-in window activity/bell flags** — `monitor-activity`/`monitor-bell` enabled in `dot_config/tmux/common.conf` so Catppuccin's `#{window_flags}` shows `#`/`!` glyphs for non-current windows that produced output or rang the bell. `monitor-silence` left disabled (agent panes have a perpetual spinner, would never fire). Option A of `backlog/tmux-window-status-indicators.md`; option C (hook-based semantic state) scoped + deferred.
- ✅ **conda/mamba lazy init** — `dot_config/zsh/tools/04_conda_mamba.zsh` finds miniforge3/miniconda3/anaconda3 and lazy-loads on first `conda`/`mamba` call.
- ✅ **NVM lazy setup** — `02_legacy_tools.zsh` wires `NVM_DIR`; opt-in via `LOAD_NVM=1` env or `load-nvm` alias to keep startup fast.
- ✅ **yazi `y()` function + ansible install** — `35_yazi.zsh` provides cwd-tracking wrapper; `devtools` role installs yazi (apt fallback to GitHub release musl binary).
- ✅ **bun / pnpm / cargo / go PATH** — wired in `02_legacy_tools.zsh` + `06_cargo.zsh`. Install side still pending (P2 above).
- ✅ **ccusage alias** — `07_bunx_cli.zsh` runs via `bunx`.
- ✅ **rust/cargo ansible role** — `rust_cargo_tools` role with `cargo-update` for upgrade flow.
- ✅ **Brewfile-based macOS package management** — XDG Brewfiles at `~/.config/homebrew/` with chezmoi `run_onchange` script (opt-in via `installBrewApps` prompt).
