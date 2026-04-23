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

## P3 — Someday / nice to have

- [ ] **[S] TA-Lib path management** — currently in `secrets.zsh` as machine-specific. Could move to a `99_local_*.zsh` create-only stub like the proxy pattern in `dot_config/zsh/99_local_proxy.zsh`.
- [ ] **[S] Try / Toolkami custom tool aliases** — currently in `secrets.zsh`. Same `99_local_*.zsh` pattern as TA-Lib above; group together.

## P? — Needs evaluation before committing

- [ ] **[?/M] tmux window status indicators — option C (hook-based per-pane state)** — option A (built-in `monitor-activity`/`bell` flags) shipped 2026-04 in `dot_config/tmux/common.conf`. Option C (semantic running/idle/error glyphs driven by Claude hooks + OpenCode plugin writing per-pane state files) is fully scoped but deferred until option A's `#` flag proves insufficient or another feature also needs the per-pane state file. Claude side is additive to `dot_claude/hooks/executable_notify.sh.tmpl` (low risk); OpenCode side is a new JS plugin (new surface, more risk). → [research](backlog/tmux-window-status-indicators.md)
- [ ] **[?/S] specstory: enable opencode auto-wrap when upstream lands** — `_sesh_wrap_agent` in `dot_config/zsh/tools/22_sesh.zsh` currently passes `opencode` through raw because specstory doesn't support it as a provider. Add to the case statement (one-line change) once `specstoryai/getspecstory#156` merges + ships. → [research](backlog/specstory-opencode-support.md)
- [ ] **[?/L] Use mise to manage most runtime versions** — already used for Node (Neovim) and Rust (Cargo) per `README.md`. Question: extend to python/go/ruby and retire ad-hoc PATH wiring + nvm? Trade-off: another layer vs unified version pinning. Spike: pick one runtime currently outside mise (go?), try alongside current setup for two weeks.
- [ ] **[?/L] Optimize zsh & tmux startup time** — needs profiling first (`zprof`, `time zsh -i -c exit`). Current state: conda/nvm are lazy-loaded already, so low-hanging fruit may be gone. Don't optimize blind.
- [ ] **[?/XL] CUDA / ML toolchain ansible role** — driver/cudnn/nccl version matrix is large; only relevant on Linux ML hosts. Defer until there's a concrete host that needs it. Likely belongs behind a new `ml_linux` profile.
- [ ] **[?/XL] SLURM client config** — same shape as CUDA above: host-specific, likely a `dot_slurm/` template gated by profile. No machine currently needs it.

---

## Done (recent, kept for context — older items pruned)

- ✅ **tmux built-in window activity/bell flags** — `monitor-activity`/`monitor-bell` enabled in `dot_config/tmux/common.conf` so Catppuccin's `#{window_flags}` shows `#`/`!` glyphs for non-current windows that produced output or rang the bell. `monitor-silence` left disabled (agent panes have a perpetual spinner, would never fire). Option A of `backlog/tmux-window-status-indicators.md`; option C (hook-based semantic state) scoped + deferred.
- ✅ **conda/mamba lazy init** — `dot_config/zsh/tools/04_conda_mamba.zsh` finds miniforge3/miniconda3/anaconda3 and lazy-loads on first `conda`/`mamba` call.
- ✅ **NVM lazy setup** — `02_legacy_tools.zsh` wires `NVM_DIR`; opt-in via `LOAD_NVM=1` env or `load-nvm` alias to keep startup fast.
- ✅ **yazi `y()` function + ansible install** — `35_yazi.zsh` provides cwd-tracking wrapper; `devtools` role installs yazi (apt fallback to GitHub release musl binary).
- ✅ **bun / pnpm / cargo / go PATH** — wired in `02_legacy_tools.zsh` + `06_cargo.zsh`. Install side still pending (P2 above).
- ✅ **ccusage alias** — `07_bunx_cli.zsh` runs via `bunx`.
- ✅ **rust/cargo ansible role** — `rust_cargo_tools` role with `cargo-update` for upgrade flow.
- ✅ **Brewfile-based macOS package management** — XDG Brewfiles at `~/.config/homebrew/` with chezmoi `run_onchange` script (opt-in via `installBrewApps` prompt).
