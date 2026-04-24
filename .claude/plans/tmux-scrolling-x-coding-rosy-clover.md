# aicapture docs + non-tmux Tier 1 wrappers + backlog for Tier 2/3

## Context

Previous phases (committed in `5c2959d` / `697eafd` / `3993b7b` / `c457a78` /
`430326d`) shipped the aicapture layer: cpout/cpcmd/cpblock with N-back
lookback, aifix/aiexplain wrappers with model defaults + glow/bat prettify
+ stderr metadata + spinner, an aiblock Python TUI with multi-select, and
an instant-llm-fix prior-art survey doc.

This phase addresses three remaining gaps surfaced in the latest chat:

1. **No user-facing "how do I use this" doc**. `docs/tools/tmux/README.md`
   has an AI section but it's embedded in a tmux-centric page; a friend
   asked to try these tools would need to read prose + reverse-engineer
   the source. Needs a dedicated `docs/tools/aicapture.md` walkthrough.
2. **Non-tmux environments** (VSCode integrated terminal, bare Ghostty
   without tmux, quick SSH sessions). cpcmd works; everything else that
   depends on tmux scrollback doesn't. Need `aifix-stdin` / `aifix-run` /
   `aifix-rerun` for the common cases.
3. **Backlog** the more invasive non-tmux options (Tier 2: transparent tee;
   Tier 3: script(1) / PTY proxy) with explicit "why not" so future-us
   doesn't spend a weekend re-deriving that they're bad trades.

User asked to sequence as: **docs first** → commit + push → then Tier 1 →
then backlog → commit + push.

## Phase A — User guide at `docs/tools/aicapture.md` (NEW)

Single-page walkthrough that stands alone. A friend can read this and
either (a) use the tools via chezmoi or (b) copy-paste the 4 source files
and use them standalone.

Sections:

- **Quick start** — one-command demo (`aifix` after a failing cargo build)
- **Commands table** — cpcmd/cpout/cpblock [N], aifix/aiexplain [N] with
  flags, aiblock TUI
- **Configuration** — the six `AICAP_*` env vars with defaults and
  meaning (the same list that `aifix --help` prints)
- **Requirements** — zsh, tmux 3.3+ (for output capture), OSC 133 hook,
  one agent CLI, optional glow/bat/jq/uv
- **Standalone setup (no chezmoi)** — curl the 4 files + sourceable
  snippet for `~/.zshrc`. Include GitHub blob URLs directly so a
  recipient can click and read without clone:
  - `dot_config/zsh/tools/02_shell_integration.zsh`
  - `dot_config/zsh/tools/03_tmux_capture.zsh`
  - `dot_config/zsh/tools/04_ai_capture.zsh`
  - `scripts/aiblock.py`
- **Troubleshooting** — `exec zsh` after install, the "shell history
  empty" bug (fixed in `3993b7b`), metadata `(?)` fallback, spinner
  visibility. Link to the two relevant pitfalls.
- **Related** — cross-refs to `tmux/README.md` OSC 133 section and
  `this_repo/instant-llm-fix-prior-art.md`.

No deployment step needed — repo is public (`github.com/daviddwlee84/dotfiles`),
no GitHub Pages set up (confirmed via Phase 1 exploration), so the share
link is the plain blob URL. Future: if we want a prettier docs site it's a
separate deferred task; `docs/` is already well-formed enough that a
future `mkdocs` config would be trivial.

**Also update**:
- `docs/tools/tmux/README.md` AI section — replace the inline usage
  paragraphs with a one-line pointer to the new aicapture.md.
- `README.md` root — if there's an existing "What You Get" or tools list,
  add a row linking to aicapture.md. (If not, skip.)

**Commit + push after Phase A so the doc is live on github.com BEFORE
implementing Tier 1.** User explicitly asked for this ordering.

## Phase B — Tier 1: three non-tmux wrappers

Three new shell functions in `dot_config/zsh/tools/04_ai_capture.zsh`,
alongside existing aifix/aiexplain:

### `aifix-stdin [-a AGENT] [-p PROMPT] [--raw] [--no-meta]`

Reads stdin as the "block". Zero magic, composes with anything.

```sh
tail -200 /var/log/nginx/error.log | aifix-stdin
curl -sS https://weird.api/thing | aifix-stdin -p "explain this JSON"
aifix-stdin < build.log
```

Default prompt same as `aifix` ("diagnose + fix"). Implementation: refactor
the dispatch to share arg parsing + agent invocation between aifix (cpblock
source) and aifix-stdin (stdin source). Introduce an internal
`_ai_dispatch_core <block> ...` that both call.

### `aifix-run [-a AGENT] [-p PROMPT] [--] CMD [ARG...]`

Runs `CMD ARG...` with stdout+stderr teed to a temp file, then feeds
`$ CMD ARG...` + captured output + exit code to the agent.

```sh
aifix-run -- cargo build --release
aifix-run -p "is this safe?" -- ansible-playbook deploy.yml
```

Implementation: `CMD "$@" 2>&1 | tee "$log"`. Capture CMD's exit code
via `${pipestatus[1]}` (zsh array). Write a small header to the log:
```
$ CMD ARG ARG
<output>
(exit code: N)
```
Then call `_ai_dispatch_core` with the log contents.

**isatty caveat** (documented, not worked around): teeing makes CMD's
stdout a pipe, so TUI apps (vim, less, htop) will render in degraded mode.
User shouldn't be aifix-run'ing interactive TUIs anyway; we leave this as
documented surprise, not a trap (no auto-whitelist — that's Tier 2
territory).

### `aifix-rerun [-a AGENT] [-p PROMPT] [-y]`

thefuck-style: fetches `fc -ln -2 -2` (skip aifix-rerun itself), confirms
`re-execute "$CMD"? [y/N]` unless `-y`, then delegates to `aifix-run --
$=CMD` with `$=` word-splitting.

**Warnings**: prints `⚠ re-executing has side effects if CMD is not
idempotent` on stderr. Safe commands (ls, cat, echo, grep, etc.) could
be added to a no-warn allowlist later; v1 just warns unconditionally
and requires explicit y.

### Docs hook-up in aicapture.md

Add a fourth section before "Configuration":

```markdown
### Non-tmux alternatives

When you don't have tmux (VSCode terminal, bare shell, short SSH):

| Command | Source of context |
|---|---|
| `aifix-stdin` | whatever you pipe in |
| `aifix-run -- CMD` | runs CMD, tees output, reviews |
| `aifix-rerun` | re-executes last command (confirm prompt) |
```

## Phase C — Backlog: `backlog/ai-capture-non-tmux-output.md` (NEW)

Follow the template at `backlog/README.md:42-91`. Single entry covers both
Tier 2 and the Tier 3 rejection, since they share a problem domain.

Shape:

```markdown
# Non-tmux output capture for aifix / aiexplain

**Status**: P2 deferred (Tier 2); P3 rejected (Tier 3)
**Effort**: M (Tier 2) / XL-won't-do (Tier 3)
**Related**: `TODO.md`, `dot_config/zsh/tools/04_ai_capture.zsh`,
  `docs/tools/aicapture.md`, `docs/this_repo/instant-llm-fix-prior-art.md`

## Context
[2026-04: committed aifix-stdin/-run/-rerun as Tier 1. What Tier 2/3 would add.]

## Investigation
[Summary of thefuck's re-run strategy, butterfish PTY proxy,
tee+isatty breakage, script(1) job-control quirks. Copy key findings
from instant-llm-fix-prior-art.md.]

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Tier 1 (shipped)** — aifix-stdin/-run/-rerun | zero magic, composes with pipe | user must remember to pipe / prefix |
| **Tier 2 — preexec/precmd tee redirect** | transparent, no per-command prefix | breaks isatty for TUIs; ZLE timing fragile; /tmp fills |
| **Tier 3a — wrap every shell in script(1)** | PTY emulation keeps isatty truthy; most robust | script(1) has bugs + zsh job-control conflicts; layer-count pain; tools detect "inside script" |
| **Tier 3b — PTY proxy (butterfish / Warp)** | richest context | effectively rewriting our own terminal |

## Decision (2026-04)

- **Tier 1 shipped** (see `5c2959d`-era commits).
- **Tier 2 deferred** — benefit limited to non-tmux-daily users; effort
  is M but testing cost is high (TUI-app matrix, ZLE interaction, disk
  usage cap). Revisit if ≥3 users report needing it OR if we find a way
  to keep `isatty(1)` truthy (PTY-pair approach).
- **Tier 3 rejected** — matches the "What we intentionally don't do"
  section of instant-llm-fix-prior-art.md. Both script(1) wrapping and
  PTY proxy require re-architecting this repo around a shell-subsuming
  wrapper, giving up portability and adding a permanent extra layer.
  The "just use tmux" answer is this repo's house style.

## References
- thefuck's eval-alias approach: [nvbn/thefuck/shells/zsh.py](https://github.com/nvbn/thefuck/blob/master/thefuck/shells/zsh.py)
- butterfish PTY proxy design: [bakks/butterfish blog post](https://pbbakkum.com/blog/20230927/)
- atuin's choice NOT to capture output: blog.atuin.sh
- pitfall: [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)
```

**TODO.md entry**: add a P? row with `→ [research](backlog/ai-capture-non-tmux-output.md)`
pointer.

## Files to modify

| Path | Action | Phase |
|---|---|---|
| `docs/tools/aicapture.md` | **NEW** — user-facing walkthrough | A |
| `docs/tools/tmux/README.md` | thin-out AI section, link to aicapture.md | A |
| `README.md` (root) | add link row if "tools" / "docs" table exists | A |
| `dot_config/zsh/tools/04_ai_capture.zsh` | refactor dispatcher; add 3 new commands | B |
| `docs/tools/aicapture.md` | add "Non-tmux alternatives" section | B |
| `docs/zsh/aliases.md` | add rows for the 3 new commands | B |
| `backlog/ai-capture-non-tmux-output.md` | **NEW** — backlog entry | C |
| `backlog/README.md` index | add row | C |
| `TODO.md` | add P? row linking to backlog entry | C |

## Existing code to reuse

- `_ai_capture_dispatch` in `04_ai_capture.zsh:109-174` — refactor into
  `_ai_dispatch_core <block-text> <name> <default-prompt> ...` so stdin /
  run / rerun paths share the existing arg parsing, spinner, prettify,
  metadata pipeline. Don't duplicate that logic.
- `_aicap_spinner_start` / `_aicap_spinner_stop` in `04_ai_capture.zsh` —
  already handles non-tty skip; new wrappers just need to call
  `_aiagent_invoke` (which spawns the spinner internally).
- `_cpx_to_clipboard` in `03_tmux_capture.zsh:24-39` — reuse for any
  "copy result to clipboard" need. Not strictly required for Tier 1.

## Commit + push plan

Two pushes, per the user's sequencing request:

**Push 1** (after Phase A):
- `docs/tools/aicapture.md` (new)
- `docs/tools/tmux/README.md` (thin-out)
- `README.md` (if applicable)
- Specstory + redact
- Message: `docs: aicapture user guide (for sharing w/o whole dotfiles)`
- **Push to origin/main so the blob URL is live**

**Push 2** (after Phases B + C):
- `dot_config/zsh/tools/04_ai_capture.zsh`
- `docs/tools/aicapture.md` (append non-tmux section)
- `docs/zsh/aliases.md`
- `backlog/ai-capture-non-tmux-output.md` (new)
- `backlog/README.md` (index)
- `TODO.md`
- Specstory + redact
- Message: `aicapture: Tier 1 non-tmux wrappers + backlog Tier 2/3 trade-offs`

## Verification

**Phase A**: open the pushed `docs/tools/aicapture.md` on github.com in a
browser, walk through Quick Start, Commands, Configuration,
Troubleshooting. Share the URL with a friend and ask them if they can
follow it standalone without any clone.

**Phase B**:
```sh
# aifix-stdin
echo "error: No such file or directory" | aifix-stdin -p "what file?"
printf 'failed\nreason: bad' | aifix-stdin --raw

# aifix-run
aifix-run -- ls /nonexistent
aifix-run -p "explain" -- curl -sSf https://httpbin.org/status/500

# aifix-rerun
false                    # last command fails
aifix-rerun              # prompts "re-execute false?" — answer n to abort
aifix-rerun -y           # prompts suppressed; reruns; feeds to agent
```

Each should print the agent reply through glow/bat with the metadata
stderr line. No tmux required; test in a plain zsh session with TMUX
unset.

**Phase C**: read the new backlog entry and the backlog/README.md index.
Confirm TODO.md has the new row. A future agent hitting "why don't we do
Tier 3" should find the answer in the "Decision" section.

## Friend-sharing quick answer (for the chat)

- **No GitHub Pages site** — confirmed by Phase 1 exploration. Repo is
  public at `github.com/daviddwlee84/dotfiles`, so all docs and source
  files are readable on github.com directly.
- **Best single URL to share post-push**:
  `https://github.com/daviddwlee84/dotfiles/blob/main/docs/tools/aicapture.md`
- **For standalone adoption** (friend doesn't want chezmoi), the
  aicapture.md page has a "Standalone setup" section with 4 raw-URL
  `curl`s + a one-line source snippet for `~/.zshrc`.
