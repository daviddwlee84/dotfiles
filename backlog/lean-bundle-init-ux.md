# Lean "no-brainer" bundles + init-CLI UX + a single source of truth for the prompt decision tree

**Status**: P? / surfaced 2026-05-21 — needs design before code; the SSOT question is the architectural part
**Effort**: L (a `cloud-vm` bundle alone is S; the CLI-UX + decision-tree-SSOT rework is L/XL)
**Related**: [`TODO.md`](../TODO.md) → `[?/L] Lean bundles + init-CLI UX …` · prerequisite [`mise-runtime-gating.md`](mise-runtime-gating.md) · downstream [`cloud-vm-provision-combo.md`](cloud-vm-provision-combo.md) · `scripts/init/dotfiles_init.py` (PROMPTS/BUNDLES/ask_bundle) · `.chezmoi.toml.tmpl` · `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` (TAGS assembly) · `Dockerfile` ARGs

## Context

2026-05-21, "dotfile on a lightweight dev machine" thread. Two distinct user pains:

1. *"別人用的情況 chezmoi init 一下子就會被一堆 custom question 給搞昏頭，所以有一些無腦可以使用的 lean bundle 確實是不錯。"* — the per-prompt flow overwhelms newcomers; named presets are the fix.
2. *"優化 CLI 的體驗…選擇配置、開關功能非常輕鬆（當然有一些可能最一開始就得決定好的選項？以及有一些是要根據機器類型有不同 prompt 的，設計起來比較複雜，且需要 somehow 維護一個 single source of truth 才比較知道整個 decision tree 是怎麼走的）。"*

The maintainer (knows every flag) is fine with the raw prompts; the problem is onboarding others + the growing, hard-to-see-as-a-whole decision tree.

## Investigation (current machinery, 2026-05-21)

There are already **two** parallel sources of prompt truth, kept in sync by hand (AGENTS.md cross-file rule):

- `.chezmoi.toml.tmpl` — the actual `promptBoolOnce` / `promptChoiceOnce` calls chezmoi runs on `init`.
- `scripts/init/dotfiles_init.py` `PROMPTS` tuple — the rich TUI (questionary) wrapper, with `BUNDLES` (named override dicts) + `ask_bundle()` picker + `doctor` that asserts the two stay aligned + a `Dockerfile` ARG mirror for non-interactive CI.

Existing bundles: `personal-mac`, `work-mac`, `server-linux`, `minimal`, `custom`. So the bundle concept the user wants **already exists** — there just isn't a lean cloud-VM one, and the raw `chezmoi init` path (no TUI) still asks everything.

Decision-tree complexity is real and multi-dimensional:
- **Machine-type-conditional prompts**: `discordChannel` is ubuntu_desktop-only; `installAiDesktopApps` is darwin-only; `nerdfonts` auto-skipped on `ubuntu_server`; oldEL/noRoot branches change mise `[tools]`. `Prompt` dataclass already carries `darwin_only` etc.
- **Decide-once-upfront vs toggle-later**: `profile`, `primaryShell`, `enableVimMode` shape downstream templating and are awkward to flip post-apply; feature `installX` flags are re-runnable (`chezmoi init` re-prompt or edit `~/.config/chezmoi/chezmoi.toml`).
- **The flag → ansible TAGS mapping** lives in a *third* place: `run_onchange_after_20_ansible_roles.sh.tmpl` builds `TAGS` from profile + `installX`. So the full "answer → what gets installed" tree spans three files.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Just add a `cloud-vm` lean bundle (+ its `chezmoi init` non-interactive flag set) | S effort; immediate onboarding win; composes with mise gating | Doesn't fix raw-`chezmoi init` overwhelm or the 3-place SSOT |
| B. Make `dotfiles_init.py` the canonical front door; raw `chezmoi init` only for re-apply | Bundle-first UX, fewer questions; one place to reason about the tree | Need a clean bootstrap (init.py needs Python/uv before chezmoi runs) — chicken/egg on a bare VM |
| C. Generate `.chezmoi.toml.tmpl` prompts + Dockerfile ARGs **from** `PROMPTS` (codegen) so there's literally one SSOT | Kills the hand-sync cross-file rule; decision tree inspectable in one file | Build-step / codegen tooling; chezmoi template can't import Python at apply time |
| D. A `dotfiles_init.py describe-tree` / `--explain` command that renders the whole profile×flag→roles decision tree from the existing dicts | Low risk; makes the tree *visible* without restructuring | Documents the sprawl rather than removing it |

## Current blocker / open questions

- **SSOT direction**: codegen (C) is the "real" fix but heavy; D (a renderer/visualiser over the existing dicts) may capture 80% of the value cheaply. Pick after the user feels how bad the tree actually is.
- **Bootstrap chicken/egg** for option B: `dotfiles_init.py` is a uv PEP-723 script; on a bare Azure VM you'd still need the curl-chezmoi one-liner first. The non-interactive `chezmoi init --promptBool ... --bundle` path may be the better lean entry than the TUI.
- Which flags are "upfront-only" vs "toggle-anytime" should be marked **in the `Prompt` dataclass** (a new field) so the UI can group them — this is the smallest concrete step toward the SSOT idea.
- Coordinate with [`mise-runtime-gating.md`](mise-runtime-gating.md): a `cloud-vm` bundle should set whatever coarse runtime flag that work lands, or it can't actually drop the ~1.8GB.

## Decision (if any)

2026-05-21 — captured for discussion. Likely sequencing: (1) ship the small `cloud-vm` bundle once mise gating exists, (2) add the upfront-vs-toggle field + an `--explain` tree renderer (D), (3) only then consider codegen (C) if hand-sync still hurts.

## References

- Footprint audit: `.specstory/history/2026-05-21_05-19-56Z-dotfile-dev-machine-heavy.md`
- AGENTS.md cross-file rules: "New `.chezmoi.toml.tmpl` prompt" row + fleet/init mirrors
- `scripts/init/dotfiles_init.py` (`PROMPTS`, `BUNDLES`, `ask_bundle`, `doctor`)
