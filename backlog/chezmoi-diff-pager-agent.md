# chezmoi diff pager — agent / non-interactive degradation

**Status**: P? deferred — investigation only, no code shipped
**Effort**: S (wrapper script + 1-line `.chezmoi.toml.tmpl` change)
**Related**: [`TODO.md`](../TODO.md) → `[P?/S] chezmoi diff pager: TTY-aware delta fallback` · `.chezmoi.toml.tmpl:102-107` (`[diff].pager`) · sibling evaluation: [`rtk-evaluation.md`](rtk-evaluation.md)

## Context

2026-05, conversation prompt: *"我們目前 `chezmoi diff 2>&1 | head -80` 會使用 delta 做 pretty print，不過如果 agent 調用的話 可能會不如 default 的 diff 清晰？或許 somehow 知道是 agent 調用 或是 non-interactive 的情況下就 fallback to default？但又不想 over engineering"*

Triggered by noticing that `chezmoi diff` piped to an agent's `Bash` tool produces output that's harder for the LLM to parse than the plain unified diff would be:

- `--side-by-side` splits each hunk into two columns, padded to a width delta guesses from `$COLUMNS`. When stdout is a pipe, that guess is wrong (often 80 or whatever the agent's PTY claims), so columns wrap mid-token and visually corrupt the diff.
- `--paging=always` is a no-op for non-TTY but `--navigate` / `--line-numbers` / coloured `--file-style` etc. still emit ANSI escape sequences. Agents see `^[[33m`-style residue inline.
- `chezmoi diff | head -80` will close the pipe early, giving delta a `Broken pipe` warning on stderr (and `2>&1` round-trips it back into the agent's view).

Default unified diff (`cat` as pager) is what every git/agent toolchain already understands and what `head` / `grep` / `tee` consume cleanly.

## Current state (`.chezmoi.toml.tmpl:102-107`)

```toml
[diff]
    exclude = ["scripts"]
{{- if lookPath "delta" }}
    pager = "delta --side-by-side --line-numbers --navigate --paging=always --file-style=yellow --file-decoration-style='yellow ul' --hunk-header-decoration-style='blue box'"
{{- end }}
```

Unconditional `delta` whenever it's on `$PATH`. No TTY check, no env-var override.

## Investigation

### Detection mechanism — three options surveyed

| Option | Pros | Cons |
|---|---|---|
| **A. `[ -t 1 ]` only** | Zero config, zero env-var maintenance. Covers `chezmoi diff \| head`, `chezmoi diff > out.diff`, agent stdout capture, CI logs — **all** correctly fall to plain because none of them are TTYs. The 1% miss case is `chezmoi diff \| less` which becomes plain unified into less; less paginates plain diff fine, no UX regression. | A user who pipes into a TTY-emulating wrapper that *re-presents* on a TTY would lose colour. No real-world example known. |
| **B. `[ -t 1 ]` + agent env allowlist** (`CLAUDECODE` / `OPENCODE` / `CURSOR_AGENT` / `CI`) | Catches the rare case of an agent that *somehow* hands its child a TTY (hasn't been observed but theoretically possible). | Allowlist drift — every new agent (Codex/Antigravity/Windsurf/Kilo/Cline/...) needs a new env var added. Maintenance tax for negligible benefit. AGENTS.md cross-tool surface already crowded. |
| **C. Opt-in env var** (`CHEZMOI_PLAIN_DIFF=1`) | Maximally conservative — never silently changes behaviour. | Useless: agent has to know to set it, user has to remember when piping. Defeats the purpose ("automatic when piped"). |

**Chosen if/when shipped**: A. The single `[ -t 1 ]` check covers 99% of real cases without a brittle allowlist. AGENTS.md already follows the same shape elsewhere (e.g., source-time `$ZSH_VERSION` / `$BASH_VERSION` detection in `dot_config/shell/`).

### Implementation surface — three options surveyed

| Option | Pros | Cons |
|---|---|---|
| **W. Wrapper script as pager** (`dot_config/chezmoi/executable_diff-pager.sh` → `pager = "{{ .chezmoi.homeDir }}/.config/chezmoi/diff-pager.sh"`) | Logic centralised, easy to test (`./diff-pager.sh < some.diff`), can grow (e.g., `--no-color` env, custom theme) without re-editing TOML. chezmoi's `executable_` prefix handles chmod. Lives under `~/.config/chezmoi/` (chezmoi's own config dir — natural home, not in `scripts/**` which is `.chezmoiignore`d). | One extra deployed file. |
| **X. Inline shell `if` in `pager`** (`pager = "sh -c 'if [ -t 1 ]; then exec delta ...; else cat; fi'"`) | No new file. | Quoting nightmare — delta args contain `'`, `"`, spaces; nesting inside `sh -c '...'` inside TOML string would need triple-escape gymnastics. Unreadable. Not testable in isolation. |
| **Y. chezmoi template-time decision** (`{{ if isExecutable "/dev/tty" }}...{{ end }}` in `.chezmoi.toml.tmpl`) | No new file, no runtime overhead. | Decided at `chezmoi init` time, not at `chezmoi diff` time. Whether init was on a TTY says nothing about whether *this particular* diff invocation is. Wrong abstraction. |

**Chosen if/when shipped**: W.

### Sketch of the wrapper

```sh
#!/usr/bin/env sh
# chezmoi diff pager wrapper.
# - TTY → delta with side-by-side / navigate (rich human view)
# - Non-TTY (pipe, redirect, agent stdout capture, CI) → cat (plain unified diff)
#
# Detection is intentionally minimal: just `[ -t 1 ]`. See
# backlog/chezmoi-diff-pager-agent.md for the alternatives considered.

if [ -t 1 ] && command -v delta >/dev/null 2>&1; then
    exec delta \
        --side-by-side \
        --line-numbers \
        --navigate \
        --paging=always \
        --file-style=yellow \
        --file-decoration-style='yellow ul' \
        --hunk-header-decoration-style='blue box'
fi

exec cat
```

`.chezmoi.toml.tmpl` becomes:

```toml
[diff]
    exclude = ["scripts"]
{{- if lookPath "delta" }}
    pager = "{{ .chezmoi.homeDir }}/.config/chezmoi/diff-pager.sh"
{{- end }}
```

### Validation plan (when shipped)

```sh
chezmoi apply ~/.chezmoi.toml ~/.config/chezmoi/diff-pager.sh
ls -l ~/.config/chezmoi/diff-pager.sh   # must be -rwxr-xr-x
chezmoi diff                            # interactive: delta side-by-side
chezmoi diff | head -80                 # piped: plain unified diff, no ANSI
chezmoi diff 2>&1 | cat                 # agent simulation: plain
```

## Why not ship now

This file is intentionally a **staged investigation** rather than a shipped change because:

1. The pain point is mild — agents *do* eventually parse the side-by-side output, just less efficiently. Not a correctness bug.
2. Shipping touches `.chezmoi.toml.tmpl` (every host re-prompts on next `chezmoi init` if logic changes — mild but non-zero churn).
3. The decision is small enough to revisit in 5 min when there's a concrete trigger (e.g., an agent session where the side-by-side wrapping caused a real misread).

When the trigger lands, this doc + the sketch above is enough to ship in one commit.

## RTK as adjacent option (rejected for this case)

[`rtk-ai/rtk`](https://github.com/rtk-ai/rtk) was floated in the same conversation as a possible alternative to this wrapper. **It's not the right tool for this job** — RTK is a token compressor, not a diff prettifier. Even if installed, it has no chezmoi filter (the supported-commands list doesn't include `chezmoi`), so `chezmoi diff` would passthrough unchanged. Full eval at [`rtk-evaluation.md`](rtk-evaluation.md).

## Decision

`2026-05 deferred` — design + sketch frozen above. Ship when:

- An agent session blows up specifically because of side-by-side wrapping (concrete trigger, not anticipated)
- Or: another tool in the repo (`git diff` / `lazygit` / etc.) hits the same TTY-detection question, justifying a shared helper instead of a one-off

## References

- delta side-by-side documentation: <https://dandavison.github.io/delta/side-by-side-view.html>
- chezmoi `[diff].pager` reference: <https://www.chezmoi.io/reference/configuration-file/variables/#diff>
- Adjacent pattern in this repo: source-time `$ZSH_VERSION` / `$BASH_VERSION` detection in `dot_config/shell/*.sh.tmpl` (see AGENTS.md → "primaryShell choice gates `chsh` only" hard invariant)
