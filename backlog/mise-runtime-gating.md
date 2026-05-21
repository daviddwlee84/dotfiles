# Gate mise runtimes (rust/dotnet/bun/ruby) behind prompts + fix the .NET-SDK contract bug

**Status**: P2 / surfaced 2026-05-21 — concrete, mechanical, blocked only on deciding the prompt shape
**Effort**: M (edit `dot_config/mise/config.toml.tmpl` `[tools]` gating + 1–4 new prompts in `.chezmoi.toml.tmpl` & `scripts/init/dotfiles_init.py` + cross-file mirrors per AGENTS.md)
**Related**: [`TODO.md`](../TODO.md) → `[M] Gate mise runtimes …` · sibling design [`lean-bundle-init-ux.md`](lean-bundle-init-ux.md) · `dot_config/mise/config.toml.tmpl` · `.chezmoi.toml.tmpl` · `scripts/init/dotfiles_init.py` PROMPTS/BUNDLES · existing P? item `[?/L] Use mise to manage most runtime versions`

## Context

2026-05-21, continuing the "dotfile on a lightweight dev machine — how heavy?" thread (see [`.specstory/history/2026-05-21_05-19-56Z-dotfile-dev-machine-heavy.md`](../.specstory/history/2026-05-21_05-19-56Z-dotfile-dev-machine-heavy.md)). Scenario narrowed to: **Azure VM, ~32GB disk, want only an ergonomic shell + tmux + nvim + high-freq coding agents (claude code / opencode / specstory).**

The disk-footprint audit found that the single biggest chunk of weight you **cannot turn off via any prompt or bundle** is the mise runtime set. On a lean cloud VM that's pure waste.

## Investigation

`dot_config/mise/config.toml.tmpl` `[tools]` for any non-oldEL (i.e. not CentOS 7), non-noRoot machine unconditionally lists:

```
node = "lts"      # genuinely needed: nvim LSP/treesitter + npm-based agents
bun  = "latest"
rust = "latest"
dotnet = "latest"
ruby = "3"
```

Measured sizes (mac power-user box, prior session — Linux similar order):

- `mise/installs` total **2.0 GB** = node 1.2G + **dotnet 653M** + ruby 118M + bun 57M (+ rust toolchain ~1G on a machine that has it)
- These install regardless of `installX` answers — the config.toml is deployed and `mise install` runs.

**Contract bug found in the same pass — and the exact trigger confirmed 2026-05-21**: the `installDotnetTools` prompt (default `False`, label *"Install .NET SDK via mise and dotnet global tools"*) only gates the `dotnet_tools` ansible role (which adds `azure-cost-cli`). The **.NET SDK itself lands even when the user answered No.** Mechanism:

- `dot_config/mise/config.toml.tmpl` deploys `dotnet = "latest"` (also `rust`/`bun`/`ruby`) **unconditionally** for non-oldEL machines — no `installX` guard.
- The **default-on** `lazyvim_deps` role (in every profile's base TAGS) runs a bare `mise install --yes` (`dot_ansible/roles/lazyvim_deps/tasks/main.yml:57`, task *"Install mise global tools (Debian/Ubuntu)"*) — **no tool argument**, so it installs *every* tool in `config.toml`, not just node. The task comment even says "(node@lts)" but the command installs all of them.
- Therefore the SDK is already on disk by the time the gated `dotnet_tools` role's `mise use -g dotnet@…` (`dotnet_tools/tasks/main.yml:42`) would run — making that role's SDK step redundant; it effectively only contributes the global tools.
- The `armv7l` branch right above (`:48`) already proves the fix shape works: it passes an **explicit** list (`mise install --yes node@20 rust@latest`, no dotnet).

So a user who explicitly declined .NET still pays ~650MB; the prompt text promises something the flag doesn't deliver. (Bug bites non-armv7l Linux + macOS; armv7l is already spared by its explicit list.)

Good-news findings (no action needed): `nerdfonts` is already excluded from the `ubuntu_server` profile TAGS (headless → fonts render client-side), and `node@lts` is legitimately required (drop would break nvim + agents).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Gate `dotnet` in config.toml on `installDotnetTools` (minimal — just fix the bug) | One-line `{{ if .installDotnetTools }}` wrap; makes prompt honest; saves 650MB on default machines | Leaves rust/bun/ruby still un-gated |
| B. Per-runtime prompts (`installRustToolchain`, keep bun under one, gate ruby on `ruby_gem_tools`) | Full control; lean VM can drop ~1.8GB | More prompt fatigue (counter to the lean-bundle UX goal) — must be defaulted sanely + folded into bundles |
| C. One coarse `installExtraRuntimes` prompt covering rust+dotnet+bun (node always on) | Simple knob; bundle-friendly | Coarse — can't drop just rust without dotnet |

Leaning **A now (fix the bug regardless) + C as the lean lever**, with bundles setting the coarse flag. Ruby is already conditional on `noRoot`; tie its `[tools]` line to whether `ruby_gem_tools` is wanted.

## Current blocker / open questions

- Decide A vs C vs B granularity — depends on the [`lean-bundle-init-ux.md`](lean-bundle-init-ux.md) decision-tree design (don't add prompts that bundles will just override anyway).
- Per AGENTS.md "New `.chezmoi.toml.tmpl` prompt" cross-file rule: any new prompt must also update Dockerfile ARG + `chezmoi init` flag + `PROMPTS`/`BUNDLES` in `dotfiles_init.py` + pass `doctor`. Factor that mirror cost into the estimate.
- oldEL path already omits node/rust/dotnet — make sure new gates compose with the existing `$oldEL` / `$noRoot` branches, don't duplicate them.

## Decision (if any)

2026-05-21 — captured, not yet scheduled. Fix the dotnet contract bug whenever mise config or the .NET prompt is next touched (cheap, correctness, not just disk).

## References

- Footprint audit transcript: `.specstory/history/2026-05-21_05-19-56Z-dotfile-dev-machine-heavy.md`
- `docs/infra/linux-toolchain-baseline.md` (oldEL glibc/libstdc++ matrix)
- `docs/this_repo/chezmoi-templating.md`
