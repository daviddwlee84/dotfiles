# For Maintainers

The repo has three agent-facing surfaces that this site **references but doesn't publish as formal documentation**, per the user's instruction ("reference yes, copy no"). They all live at the repo root and are readable on GitHub directly.

## Agent contract

`CLAUDE.md` (alias: `AGENTS.md`, `GEMINI.md` — all three are symlinks to the same file) is the agent-facing contract: cross-file maintenance rules, hard repo invariants, chezmoi conventions. Coding agents working in this repo MUST read it before making changes.

→ [**CLAUDE.md**](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md)

Out-of-band notes the user keeps for themselves (usually work-in-progress thoughts, not intended as durable documentation):

→ [NOTES.md](https://github.com/daviddwlee84/dotfiles/blob/main/NOTES.md)

## TODO index

`TODO.md` is the single long-term backlog index. Each row carries a priority tag (`P1` / `P2` / `P3` / `P?`) and effort tag (`S` / `M` / `L` / `XL`). Rows with `→ [research](backlog/<slug>.md)` links have accompanying design notes / investigation.

→ [**TODO.md**](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md)

## Backlog (research / design notes)

`backlog/` holds per-topic research notes for items that need evaluation before committing, have multiple options considered, or represent paused troubleshooting. Each entry follows a Context / Investigation / Options / Decision / References template.

→ [**backlog/** directory](https://github.com/daviddwlee84/dotfiles/tree/main/backlog) · [backlog/README.md](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/README.md) · full index below

Examples relevant to the aicapture work documented on this site:

- [`ai-capture-non-tmux-output`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/ai-capture-non-tmux-output.md) — why we shipped Tier 1 but defer Tier 2 (transparent tee) and reject Tier 3 (PTY proxy / `script(1)`)
- [`tmux-window-status-indicators`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/tmux-window-status-indicators.md) — option C (hook-based semantic state) deferred
- [`starship-context-modules`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/starship-context-modules.md) — ready-to-go enablement of status/cmd_duration/shlvl/container

## Pitfalls (symptoms-first knowledge base)

`pitfalls/` is a grep-friendly catalogue of past traps — each entry is titled by the **symptom**, not the root cause, and keeps verbatim error messages so a future agent hitting the same error finds the workaround instantly.

→ [**pitfalls/** directory](https://github.com/daviddwlee84/dotfiles/tree/main/pitfalls) · [pitfalls/README.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/README.md)

Examples referenced from public docs on this site:

- [`tmux-scrollback-tui-repaint-ghosting`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-scrollback-tui-repaint-ghosting.md) — why Claude Code / OpenCode scrollback sometimes looks duplicated
- [`zsh-osc133-precmd-printf-a-not-stored`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-osc133-precmd-printf-a-not-stored.md) — the ZLE timing trap behind the `%{...%}`-embedded OSC 133 A marker
- [`tmux-display-menu-silent-fail`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-display-menu-silent-fail.md) — the height-fit menu suppression debugging story

## The project-knowledge-harness skill

TODO / backlog / pitfalls are collectively managed by the `project-knowledge-harness` agent skill. When to use which, naming conventions, and the "graduates to Hard invariant" rule are covered in [`CLAUDE.md`](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md) → "Long-term backlog + past pitfalls".

## In-site maintenance references

A few published docs primarily serve maintainers (not end users browsing for "how do I configure tool X"). They're in the main site nav but worth flagging here as the entry points when you're working on the repo itself:

- [`this_repo/architecture.md`](this_repo/architecture.md) — install-flow phases, profile / tag matrix, no-root mode
- [`this_repo/tool-managers.md`](this_repo/tool-managers.md) — **install-side reference**: which manager owns which tool (per-manager catalog + A–Z lookup + decision tree for new tools)
- [`this_repo/upgrades.md`](this_repo/upgrades.md) — **upgrade-side reference**: `just upgrade-*` categories + what `chezmoi apply` will NOT do
- [`this_repo/uv-bootstrap.md`](this_repo/uv-bootstrap.md) — why uv is special (Python's-own-pip pitfalls + brew-vs-curl dispatch)
- [`this_repo/sudo-session.md`](this_repo/sudo-session.md) — the shared sudo cache used across all three run-scripts
- [`this_repo/fleet-apply.md`](this_repo/fleet-apply.md) — multi-host `chezmoi apply` orchestration

---

Why these aren't site content:

- **TODO.md / backlog/ / pitfalls/** are *dynamic* — they change commit-by-commit as the user surfaces ideas and debugs new traps. Duplicating them into the site would create drift between rendered pages and the live GitHub source. A reference-only page (this one) keeps the single source of truth at the repo root.
- **CLAUDE.md** is agent-operational text, not end-user docs. It's deliberately written for a coding agent about to modify this specific repo. Unlisted from the main site nav but linked here for transparency.
