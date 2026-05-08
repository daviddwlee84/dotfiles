# fish vs. current zsh setup — does fish still buy us anything?

**Status**: P? deferred — evaluation only, no install
**Effort**: L (full port estimated ~400 LOC translation + ansible role; see TODO `[P3/L] Add fish as a third primaryShell choice`)
**Related**: [`TODO.md`](../TODO.md) → `[P3/L] Add fish as a third primaryShell choice` · [`docs/shells/architecture.md`](../docs/shells/architecture.md) · [`AGENTS.md`](../AGENTS.md) → "primaryShell choice gates chsh only"

## Context

2026-05, conversation prompt: *"fish vs. 我們現在的zsh配置能有什麼優勢嗎？還是也配得差不多了？"*

The question came up while reviewing the current shell stack (zsh + bash dual-tier with `dot_config/shell/` POSIX shared layer). Goal of this doc: freeze the trade-off analysis so we don't re-litigate it next time fish comes up, and so the existing `[P3/L] Add fish as a third primaryShell choice` TODO has a real decision log to point at instead of just scoping notes.

## Investigation

### Feature parity — what fish ships by default vs what our zsh already has

| fish out-of-the-box feature | Current zsh equivalent in this repo |
|---|---|
| Autosuggestion (grey inline preview) | `zsh-autosuggestions` + `aisuggest` (Alt+;, AI-powered — fish has no equivalent) |
| Syntax highlighting | `fast-syntax-highlighting` |
| fzf-style history search | `atuin` (cross-machine sync, SQLite, strictly stronger than fish's built-in history) |
| Smart completions (auto-generated from man pages) | zsh `compinit` + `carapace` + per-tool completions |
| Pretty prompt | `starship` (fish itself uses starship too) |
| Directory jumping | `zoxide` |
| Tab completion menu with arrow-key selection | zsh `menu-select` |

Plus zsh-only surfaces in this repo that fish does NOT have equivalents for:

- `sesh` + tmux integration ZLE widgets (Alt+S/G/E/A/I/T/R/P)
- `tools_picker` / `television` ZLE widgets
- `aisuggest` (AI completion)
- `zsh-vi-mode` + custom `zvm_after_init` keybind restoration (rebinds Alt+* widgets after zsh-vi-mode wipes them)
- Cross-shell `dot_config/shell/` POSIX shared tier (sourced by both zsh and bash)

### Where fish still genuinely leads

1. **Cleaner script syntax** — `if test -f foo` vs `[[ -f foo ]]`, no `$(())` quoting trap, function definitions don't need `()`, explicit variable scoping (`set -lx` / `-gx`). Less footgun-prone for new shell scripts.
2. **Zero-config UX** — `brew install fish` and you're done; we spent significant time tuning zsh to get the same baseline. Lower ceiling though.
3. **`fish_config` web UI** — browser-based prompt/colour/keybind editor. Cute, not load-bearing.
4. **`abbr` (abbreviations)** — strictly better than aliases: expand to the real command at space/enter, editable inline, history records the expanded form. zsh has `zsh-abbr` plugin but it's not built-in.
5. **POSIX-incompatibility as a feature** — forces you to not copy-paste random bash one-liners, fewer pitfalls.

### Where fish is a regression for THIS repo

1. **Not POSIX**. The `dot_config/shell/*.sh.tmpl` three-tier architecture (shared → zsh-only / bash-only) breaks. fish cannot source POSIX scripts; env vars, functions, aliases would all need a `.fish` rewrite. Going from "zsh + bash dual-tier" to "zsh + bash + fish triple-tier" — or dropping bash entirely.
2. **Often missing on servers**. SSH into a customer's customer's box: bash always there, zsh usually there, fish usually not. Means another ansible role and a host-availability assumption that frequently fails.
3. **Smaller ecosystem**. `zsh-vi-mode`, `atuin` ZLE integration, `zsh-autosuggestions` AI hooks, `carapace` completion quality — all more mature on the zsh side. `sesh`'s fish integration is sparse.
4. **Cannot directly use shell snippets from the wild**. ~99% of Stack Overflow shell answers are bash/POSIX; every paste needs translation.
5. **Massive sunk cost**. `docs/shells/`, `pitfalls/` shell entries, `AGENTS.md`'s shell-tier rules, the ble.sh + OMB 12-step init order, the `zvm_after_init` keybind fix — all redundant if we switch.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Switch primary shell to fish | Cleaner script syntax; zero-config baseline | Triple-tier shared/zsh/bash/fish; redundant ansible role; loses ZLE widgets (sesh / tools_picker / television / aisuggest); breaks SSH-to-server workflow |
| B. Add fish as optional non-default | Low cost; user can `fish` ad-hoc to play with abbreviations / syntax | Still requires ansible role + minimal `dot_config/fish/conf.d/`; ZLE widget gap means it's never as featureful as the zsh side |
| C. Stay on zsh + bash, do nothing | Zero work; keeps the invariant that all features work in primary shell | Misses the "play with abbr" learning surface |

## Decision

**2026-05 — option C (stay on zsh + bash, do nothing).**

Rationale:

- Feature gap fish would close: ~5% (mostly `abbr`, syntax cleanliness for ad-hoc scripts).
- Feature regression fish would introduce: significant (loses 4+ ZLE widgets, breaks shared POSIX tier, forces new ansible role).
- Threshold for revisiting: *"`[[ ]]` / `$()` / `IFS` / `set -e` quirks consume >30% of my shell-script-writing time"* — currently nowhere near, since heavy-lifting scripts already live in Python (`scripts/*.py` with PEP 723 inline deps) and shell tier is small POSIX helpers.
- Existing `[P3/L]` TODO entry remains valid as a scoping reference for the future port, but downgraded from "wait until first user wants fish" to "explicitly evaluated and declined; revisit only if shell-script friction crosses the 30% bar".

Option B (optional non-default install) was considered and also declined — even an `ansible-role-fish` that doesn't `chsh` carries the maintenance cost of: keeping the role healthy, deciding whether it gets a `dot_config/fish/conf.d/` scaffold (otherwise fish's first-run experience is worse than the bare zsh we tuned), and remembering to test it. The `dot_config/zsh/` + `dot_config/bash/` dual surface is already at the upper bound of what's worth maintaining for one user.

## Open question for revisit

If the user picks up `abbr` envy from someone else's setup and the only blocker is "abbreviations would be nice", the cheaper path is **`zsh-abbr` plugin** (added to `dot_config/zsh/.zshrc.d/` in one line) rather than switching shells. Try that first.

## References

- [`docs/shells/architecture.md`](../docs/shells/architecture.md) — full multi-shell scoping including fish 3.x and PowerShell Core 7+ entries
- [`AGENTS.md`](../AGENTS.md) → "primaryShell choice gates chsh only — both shells always deploy" — the invariant that constrains how a third shell would be added
- [`TODO.md`](../TODO.md) → `[P3/L] Add fish as a third primaryShell choice` — the scoping entry this doc decides against
- fish docs: <https://fishshell.com/docs/current/>
- `zsh-abbr` (cheaper alternative to switching for the `abbr` feature): <https://github.com/olets/zsh-abbr>
