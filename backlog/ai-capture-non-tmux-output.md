# Non-tmux output capture for aifix / aiexplain

**Status**: P2 deferred (Tier 2); **P3 rejected** (Tier 3)
**Effort**: M (Tier 2) / XL-won't-do (Tier 3)
**Related**: [`TODO.md`](../TODO.md) · [`dot_config/zsh/tools/04_ai_capture.zsh`](../dot_config/zsh/tools/04_ai_capture.zsh) · [`docs/tools/aicapture.md`](../docs/tools/aicapture.md) · [`docs/this_repo/instant-llm-fix-prior-art.md`](../docs/this_repo/instant-llm-fix-prior-art.md)

## Context

**2026-04**: shipped `aifix` / `aiexplain` / `cpblock` / `aiblock` which all require tmux because they lean on OSC 133 line-attribute tracking in tmux's grid. Users in non-tmux environments (VSCode integrated terminal, bare Ghostty without tmux, quick SSH where starting tmux is inconvenient) can use `cpcmd` (shell history — input only) but not the output-level capture.

Tier 1 shipped in the same batch: `aifix-stdin` / `aifix-run` / `aifix-rerun` — three zero-magic wrappers where the user explicitly provides the context (stdin / fresh invocation / re-execute). They cover the common cases but require the user to remember which one to pick.

This entry records what a more-transparent "Tier 2" or "Tier 3" would look like, and — more importantly — **why we're not building them**, so future-us doesn't spend a weekend rediscovering these trade-offs.

## Investigation

From [`docs/this_repo/instant-llm-fix-prior-art.md`](../docs/this_repo/instant-llm-fix-prior-art.md), the four known strategies for "bound the previous command":

1. **Shell history file** — only sees the command string, no output. What `thefuck` does; works fine for typos, useless for runtime errors.
2. **Shell hooks + OSC 133** — what we do. Needs a terminal multiplexer or OSC-133-aware terminal to store the markers; tmux consumes the marker bytes into grid line attributes and doesn't re-emit them from `capture-pane -pe`.
3. **tmux `capture-pane`** — what `wut` / `tmuxai` / our `cpblock` do. Fails outside tmux.
4. **PTY proxy** — `butterfish` / Warp. The AI shell IS the terminal.

No one has a "automatic, no shell integration, no PTY proxy, no tmux" solution — it's a physics limit, not an engineering gap.

### thefuck's approach (for comparison)

```zsh
# thefuck/shells/zsh.py fuck() alias snippet
TF_HISTORY="$(fc -ln -10)"
TF_CMD=$(thefuck THEFUCK_ARGUMENT_PLACEHOLDER "$@") && eval $TF_CMD
```

Then Python:

```python
proc = Popen(script, shell=True, env=..., stderr=STDOUT, stdout=PIPE)
output = proc.communicate(timeout=settings.wait_command)[0]
```

**It re-runs the command** to get stdout+stderr — exactly what our Tier 1 `aifix-rerun` does, but with less ceremony. Cost: `rm`, `curl -X POST`, `cargo build` get executed twice.

### atuin's choice to NOT store output

[atuin](https://github.com/atuinsh/atuin) is the closest "serious shell-history database" project. It stores command, exit code, duration, cwd, host — [explicitly not output](https://blog.atuin.sh/) because output is typically large and rarely needed later. If we went further we'd be reinventing their design space; better to compose with atuin than compete.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **Tier 1 (SHIPPED)** — `aifix-stdin` / `aifix-run` / `aifix-rerun` | Zero magic, composes with any pipe, user has full control | User must remember to prefix / pipe; no "just works after a failed command" reflex |
| **Tier 2 — zsh preexec/precmd tee redirect** | Transparent: user just runs commands, `aifix` finds the output automatically | `exec > >(tee FILE)` breaks `isatty(1)` for the running command → TUI apps (vim, less, htop, ncurses) render in degraded mode; ZLE timing is fragile (same family as the [OSC 133 A-marker pitfall](../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)); `/tmp` fills up if not capped |
| **Tier 3a — wrap every shell in `script(1)`** | PTY emulation keeps `isatty(1)` truthy, so TUIs still work | `script(1)` has job-control quirks with zsh (fg/bg misbehave), some tools detect they're "inside script" and change behaviour, log files pile up, you end up with layers like `zsh inside script inside tmux inside terminal` which is hell to debug |
| **Tier 3b — PTY proxy (butterfish-style)** | Richest context (every keystroke + every output byte) | Effectively rewriting our own terminal; gives up portability; puts us in the Warp/butterfish product category which this repo intentionally isn't |

## Current blocker / open questions

**Deferred, not blocked.** Tier 1 (shipped) handles the common cases. Tier 2 needs research on keeping `isatty(1)` truthy under tee (maybe a PTY-pair shim? Maybe `zpty` from `zsh/zpty` module?). Tier 3 is a deliberate "no" — see Decision below.

Re-evaluate Tier 2 if:

- Three or more users (or recurring personal workflows) report needing output capture in non-tmux sessions specifically, AND the Tier 1 commands aren't good enough;
- Someone finds a clean way to keep `isatty(1)` truthy during transparent tee, maybe via `zsh/zpty` module or a custom `mkfifo` dance;
- The TUI-app-breakage testing burden becomes tractable (a small curated whitelist turns out to be 95% sufficient).

## Decision (2026-04)

- **Tier 1 shipped** in the same batch as this backlog entry.
- **Tier 2 deferred** — the effort is "Medium" (maybe 4-8 hours of plumbing) but the *testing* burden is L-to-XL: we'd need to validate against every TUI the user runs (vim, nvim, less, htop, btop, lazygit, fzf, tldr, systemctl status, journalctl -f, tmux-itself…) to make sure we aren't breaking them. Benefit is limited to the subset of users who (a) work without tmux daily AND (b) hit the "forgot to pipe" reflex often enough that Tier 1 isn't good enough. Low ROI.
- **Tier 3 rejected.** Matches the "What we intentionally don't do and shouldn't start" section of [`instant-llm-fix-prior-art.md`](../docs/this_repo/instant-llm-fix-prior-art.md). Both variants require re-architecting this repo around a shell-subsuming wrapper, giving up portability and adding a permanent extra layer. "Just use tmux" is this repo's house style — we already have the tmux invariant (see [`CLAUDE.md`](../CLAUDE.md) → tmux ≥ 3.3 required for popup menu), so asking output-capture users to do the same isn't a new constraint.

## References

- thefuck's eval-alias approach: [nvbn/thefuck/shells/zsh.py](https://github.com/nvbn/thefuck/blob/master/thefuck/shells/zsh.py)
- butterfish PTY proxy design post: [pbbakkum.com/blog/20230927](https://pbbakkum.com/blog/20230927/)
- atuin's decision to not capture output: [blog.atuin.sh](https://blog.atuin.sh/)
- Related pitfall about ZLE timing: [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)
- Prior art survey: [`docs/this_repo/instant-llm-fix-prior-art.md`](../docs/this_repo/instant-llm-fix-prior-art.md)
