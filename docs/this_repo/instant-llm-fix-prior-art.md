# Instant LLM Fix: Prior Art

## Why this exists

`thefuck` (nvbn, 2015) was the original reflex for "my last command errored, correct it for me" — a rule-based Python daemon that inspects `$history[-1]` and pattern-matches against ~200 handwritten rules (`git_push`, `no_command`, `sudo_command_not_found`, …). It works until it doesn't: any command not in the rule set returns nothing, and the project has drifted into sporadic maintenance (last tagged release 3.32 in Jan 2024, open PR #1465 for `imp`→`importlib` still unmerged, issue #1466 literally titled "The repo is dead"). The LLM era reframes the same reflex: instead of pattern-matching, dump the last command + its stderr + optional scrollback at a model and let it propose a fix or an explanation. Our `cpblock`/`cpout`/`cpcmd` + `aifix`/`aiexplain` pipeline is one instance of that pattern; this page inventories the others.

## LLM-powered successors to thefuck

| Tool | Lang | Bounds "last command" via | Last release | Status | Notes |
|---|---|---|---|---|---|
| `shell_gpt` (`sgpt`) | Python | Shell integration hotkey; generates a NEW command from NL, does not auto-capture prior output | active (1.x line, 2025) | healthy | [TheR1D/shell_gpt](https://github.com/TheR1D/shell_gpt). `--shell` flag, `Ctrl+L` binding, confirm/edit/execute loop. Closer to Copilot-for-shell than to thefuck. |
| `aichat` | Rust | `-e` execute mode + `-c` code mode; shell integration script binds Alt+E to "replace current buffer with generated command" | active, frequent releases | healthy | [sigoden/aichat](https://github.com/sigoden/aichat), integration scripts for bash/zsh/fish/nu/PowerShell at [scripts/shell-integration](https://github.com/sigoden/aichat/tree/main/scripts/shell-integration). Unified provider layer (OpenAI/Claude/Gemini/Ollama/Groq). |
| `ai-shell` | TS/Node | Prompt → command. Does NOT capture prior output; user describes intent in NL | semi-active, less frequent | maintained | [BuilderIO/ai-shell](https://github.com/BuilderIO/ai-shell). Classic three-button UX (run / revise / cancel). OpenAI-only by default. |
| `llm` (Simon Willison) | Python | No shell integration of its own — it's a pipe. You build the capture yourself (`<cmd> 2>&1 \| llm "explain"`) | very active (0.30 line, 2026) | healthy | [simonw/llm](https://github.com/simonw/llm). Plugin model for providers + tools; logs everything to SQLite for Datasette. This is the "low-level Lego brick" everyone else could have been built on. |
| `wut` | Python | **tmux or screen required** — calls `tmux capture-pane -p -S -` to grab last block | v0.x, active-ish | healthy | [shobrook/wut](https://github.com/shobrook/wut). Closest philosophical twin to our `aiexplain`. OpenAI/Anthropic/Ollama. `pipx install wut-cli`. [Show HN](https://news.ycombinator.com/item?id=42462764). |
| `tmuxai` | Go | tmux pane observation — reads the visible content of every pane in the current window | active, 2025 releases | healthy | [alvinunreal/tmuxai](https://github.com/alvinunreal/tmuxai), [tmuxai.dev](https://tmuxai.dev/). Runs in a chat pane, executes in a target pane, has a "watch mode" that auto-suggests. Heavier than wut — it's a pair-programmer model, not a one-shot explainer. |
| `butterfish` | Go | Wraps the shell as a PTY proxy — sees every keystroke + every output byte | v0.2.15 (May 2024), quiet since | low-maintenance / coasting | [bakks/butterfish](https://github.com/bakks/butterfish). Capital-letter-first-word triggers prompt. The most invasive architecture (full PTY proxy) but also the richest context. Author [wrote it up](https://pbbakkum.com/blog/20230927/). |
| `shell-ai` (ricklamers) | Python | NL → command, no capture | semi-active | maintained | [ricklamers/shell-ai](https://github.com/ricklamers/shell-ai). LangChain-based, another "describe intent → suggest command" flavour. |
| `thefuck` itself | Python | zsh/bash hook reads last command from history | 3.32 (Jan 2024), issue #1466 | drifting | [nvbn/thefuck](https://github.com/nvbn/thefuck). Still works, still installed by millions; rule set frozen in amber. |

The split on "bounds the previous command" is the load-bearing axis here. Four strategies in use:

1. **Shell history file** (`thefuck`, `sgpt`) — only sees the command string, never the output. Fine for syntax typos, useless for runtime errors.
2. **Shell hook emitting before/after markers** (`atuin`, OSC 133) — knows exactly where a command started and ended, including exit code.
3. **tmux/screen `capture-pane`** (`wut`, `tmuxai`, our `cpblock`) — borrows the terminal multiplexer's scrollback. Works without touching the shell; fails outside tmux.
4. **PTY proxy** (`butterfish`, Warp) — the AI shell IS the terminal. Most context, most lock-in.

## Terminal-native competitors

| Tool | Open? | Hook | Status |
|---|---|---|---|
| [Warp](https://www.warp.dev/) | Proprietary, closed source | Native Electron + Rust terminal; treats every command as a [block](https://docs.warp.dev/features/blocks) with input/output/exit-code as first-class fields | Active; raised Series B, added full [agent platform](https://docs.warp.dev/agent-platform/warp-agents/interacting-with-agents/terminal-and-agent-modes) |
| [Amazon Q Developer CLI](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line.html) (née Fig) | Open source CLI, proprietary backend; specs repo [withfig/autocomplete](https://github.com/withfig/autocomplete) | Inline ghost-text autocomplete via `@withfig/autocomplete` specs + `q chat` subcommand | Fig sunset [Sep 1, 2024](https://fig.io/blog/post/fig-is-sunsetting); rolled into Amazon Q. macOS-first, Linux/Windows roadmap slipping |
| [Ghostty](https://ghostty.org/) shell integration | Open source (MIT) | Native OSC 133 emitter for bash/zsh/fish/elvish/nushell — see [DeepWiki: OSC 133 Prompt Marking](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking) | Active, reference implementation |
| [WezTerm](https://wezterm.org/shell-integration.html) shell integration | Open source (MIT) | Native OSC 133, plus OSC 7 (CWD) and OSC 1337 (iTerm compat) | Active |
| [Kitty](https://sw.kovidgoyal.net/kitty/shell-integration/) shell integration | Open source (GPLv3) | Its own `KITTY_SHELL_INTEGRATION` protocol — emits OSC 133 subset + more | Active |
| [iTerm2](https://iterm2.com/documentation-shell-integration.html) | macOS-only, proprietary | Original popularizer of OSC 133-style semantic prompts | Active |
| Warp's clone, [cmux](https://github.com/cmux/cmux) and similar | Open source attempts | varies | Too young to rely on |

The through-line: **Warp is the only one where the AI is the headline feature**. Everyone else is a terminal that happens to emit shell-integration markers so OTHER tools (tmux, Zed, VSCode, our `cpblock`) can build AI on top. Given we already have tmux + OSC 133, we get 90% of Warp's "jump to prompt" / "copy last output" / "attach to agent" interactions without migrating away from zsh.

## Shell integration layer (what lets ALL of this work)

OSC 133 (["semantic prompts"](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md)) is the cross-terminal protocol that turns the scrollback from a flat byte stream into a structured sequence of `{prompt_start, command_start, output_start, command_finished(exit_code)}` records. Once a pane is marked up, any layer above it — terminal emulator, multiplexer, external script — can answer "give me the last command block" without parsing prompts heuristically.

| Layer | Role | Our repo |
|---|---|---|
| Shell | Emits `\e]133;A/B/C/D\a` at the right moments | `dot_config/zsh/tools/02_shell_integration.zsh` |
| Terminal emulator | Parses OSC 133 for in-terminal jumping (Ghostty `Ctrl+Shift+J/K`, iTerm2 `Cmd+Shift+Up/Down`) | Ghostty/iTerm2 for free |
| Multiplexer | Exposes `tmux send-keys -X previous-prompt` / `next-prompt`, attaches line attributes in scrollback | tmux 3.2+ |
| Capture tool | `tmux capture-pane -pS -` + line-attr-aware range extraction | `dot_config/zsh/tools/03_tmux_capture.zsh` (`cpblock`/`cpout`/`cpcmd`) |
| LLM wrapper | Takes the captured block, ships it to Claude/OpenAI, renders fix/explanation | `aifix` / `aiexplain` + Python TUI |

The load-bearing pitfall we already hit: emitting the **A** marker via `printf` from the `precmd` hook looks correct, but zsh's line editor (ZLE) does cursor-positioning work between precmd and the prompt paint, which desynchronises tmux's per-line attribute tracking. tmux ends up with the A attribute attached to a transient row, then ZLE redraws the prompt on a different row — so `previous-prompt` finds zero A markers in the scrollback even though the escape bytes were "emitted" (see [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](../../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)). The fix — embedding the A marker into `$PROMPT` via zsh's `%{...%}` zero-width wrapper so it lands spatially at the prompt start — is the same workaround [iTerm2 has been shipping since 2016](https://iterm2.com/documentation-shell-integration.html). Every shell-integration layer in this list silently depends on that workaround (or the equivalent PS1 embed) being correct; if it isn't, `tmuxai`, `wut`, our capture helpers, and Warp-style block copying all break in the same subtle way.

[`atuin`](https://github.com/atuinsh/atuin) belongs in this layer too. It's not AI itself (18.15 added an optional desktop AI, but the core is a SQLite-backed history with cwd, exit code, duration, host). It's the "upgrade your history file to a database" piece that every other tool would want if it cared about context beyond last-command. Actively maintained — [v18.15.1 in April 2026](https://github.com/atuinsh/atuin/releases), and [v18.13's devlog](https://blog.atuin.sh/atuin-v18-13/) announced a PTY proxy + AI features moving into scope.

## Adjacent designs worth knowing

- **asciinema + LLM** ([asciinema/asciinema](https://github.com/asciinema/asciinema)): `.cast` files are time-stamped JSON, trivially parseable. Several [asciinema.org demos](https://asciinema.org/a/592283) show piping a cast through a local model for "summarise this session" or "reproduce this bug". The 2x win: casts are text, tiny, diffable, and cross a human/agent boundary well. The cost: you only get this retrospectively — doesn't help the "fix the command I just ran" reflex.
- **`script(1)` + LLM**: POSIX's pre-asciinema session logger. Captures raw bytes including control codes; strip them with `col -b` and feed to a model. Exists on every Unix and requires zero install. The 1990s solution that still beats a lot of 2024 tooling for air-gapped machines.
- **Jupyter-in-shell**: [`xonsh`](https://xon.sh/) and [`elvish`](https://elv.sh/) let you mix shell and Python/lisp in the same REPL. [`nushell`](https://www.nushell.sh/) goes further — every command returns structured data, which makes `ls | where size > 1mb | to json | llm "which of these are logs"` feel natural. See [gpt2099.nu](https://github.com/cablehead/gpt2099.nu) for a nushell-native LLM/MCP bridge. The trade-off: you're migrating shells, which is a decade-long commitment.
- **Agent thinking panels**: [Aider issue #2742](https://github.com/Aider-AI/aider/issues/2742) proposes exactly what `wut` already does, but from inside a dedicated agent UI. The pattern of a dedicated tmux pane that visualises agent state (thinking tokens, tool calls, file diffs) is converging across Aider, Claude Code, OpenCode, Codex CLI. None of them currently expose "here's my last broken command, fix it" as a zero-friction reflex — you have to paste into the agent.

## How this repo's aicapture compares

**What we do well**

- Built on OSC 133 from the start, so the same markers that make `tmuxai` / `wut` / Ghostty's built-in "jump to prompt" work also drive our `cpblock`/`cpout`/`cpcmd`. No lock-in to our capture layer.
- Three distinct scopes (`cpcmd` = command only, `cpout` = output only, `cpblock` = both). Warp calls this "block copy"; `wut` only supports the combined form. Cheaper to iterate with small scopes.
- N-back lookback on each scope (`cpblock 3`, `cpout 2`, …) so errors two commands ago are still addressable. `wut` / `tmuxai` only expose "last block".
- Fix vs. explain split (`aifix` vs `aiexplain`) — most competitors conflate these, giving you explanations when you wanted an executable replacement. Matches the mental model thefuck users already have.
- Python TUI for review-before-exec — closest in UX to `aichat`'s confirm loop and Warp's agent preview.
- Shell-hook-agnostic ingestion: the captured block is text, so it composes with `llm`, `sgpt`, local Ollama, anything that reads stdin.

**What the alternatives do better (worth stealing)**

- **sgpt / aichat**: inline editable buffer. They rewrite `$BUFFER` in-place so you can edit the AI's suggestion before Enter. We hand back text via stdout / the TUI; a zle widget for the common case ("shift+enter after aifix to accept into buffer") would save a clipboard round-trip.
- **atuin**: persistent history of failures, not just last one. Building a `fails` subcommand that greps our command history for nonzero exit codes would turn `aifix` into a batch tool ("fix every failing npm install from today").
- **llm (simonw)**: logs all prompts/responses to SQLite + Datasette. We throw our completions away. Keeping a local SQLite of `{captured_block, fix_suggestion, did_user_accept}` would let us fine-tune prompts against our own track record.
- **wut / tmuxai**: single static binary or `pipx install`. Our stuff ships via chezmoi which means it doesn't work on a machine that hasn't run `chezmoi apply`. A standalone `aifix` bin (Python zipapp or uvx-ready entry point) would be portable to ad-hoc remotes.
- **Warp agent mode**: "attach last error as context" is one hotkey. Ours requires `cpblock | pbcopy` then paste into Claude Code. A direct `aifix --to-claude-code` that spawns a Claude Code session with the block pre-loaded would close the gap (the `aiblock` TUI's "Spawn agent" action is the closest we have today — via paste-buffer, not direct injection).

**What we intentionally don't do and shouldn't start**

- Full PTY proxy (Butterfish, Warp): gives up too much portability.
- Native terminal rewrite: covered by Ghostty + tmux, no point competing.
- Command autocomplete from NL (ai-shell, sgpt, aichat `-e`): out of scope — that's "write the command", we're "fix the command".

## Sources

- [nvbn/thefuck](https://github.com/nvbn/thefuck), [issue #1466 "The repo is dead"](https://github.com/nvbn/thefuck/issues/1466)
- [TheR1D/shell_gpt](https://github.com/TheR1D/shell_gpt)
- [sigoden/aichat](https://github.com/sigoden/aichat), [shell-integration scripts](https://github.com/sigoden/aichat/tree/main/scripts/shell-integration)
- [BuilderIO/ai-shell](https://github.com/BuilderIO/ai-shell)
- [simonw/llm](https://github.com/simonw/llm), [LLM 0.26 tools post](https://simonw.substack.com/p/large-language-models-can-run-tools), [language-models-on-the-command-line talk](https://github.com/simonw/language-models-on-the-command-line)
- [shobrook/wut](https://github.com/shobrook/wut), [Show HN](https://news.ycombinator.com/item?id=42462764)
- [alvinunreal/tmuxai](https://github.com/alvinunreal/tmuxai), [tmuxai.dev](https://tmuxai.dev/)
- [bakks/butterfish](https://github.com/bakks/butterfish), [design blog](https://pbbakkum.com/blog/20230927/)
- [ricklamers/shell-ai](https://github.com/ricklamers/shell-ai)
- [Warp docs — Warp AI](https://docs.warp.dev/features/warp-ai), [Agent modes](https://docs.warp.dev/agent-platform/warp-agents/interacting-with-agents/terminal-and-agent-modes), [Classic Input](https://docs.warp.dev/terminal/classic-input)
- [Fig is sunsetting](https://fig.io/blog/post/fig-is-sunsetting), [Amazon Q Developer CLI docs](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line.html), [aws/amazon-q-developer-cli-autocomplete](https://github.com/aws/amazon-q-developer-cli-autocomplete), [withfig/autocomplete](https://github.com/withfig/autocomplete)
- [OSC 133 semantic-prompts spec (freedesktop)](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md)
- [Ghostty OSC 133 (DeepWiki)](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking), [Ghostty issue #5932](https://github.com/ghostty-org/ghostty/issues/5932)
- [WezTerm shell integration](https://wezterm.org/shell-integration.html)
- [iTerm2 shell integration](https://iterm2.com/documentation-shell-integration.html)
- [tmux OSC 133 issue #3064](https://github.com/tmux/tmux/issues/3064)
- [atuinsh/atuin](https://github.com/atuinsh/atuin), [v18.13 devlog](https://blog.atuin.sh/atuin-v18-13/), [releases](https://github.com/atuinsh/atuin/releases)
- [asciinema/asciinema](https://github.com/asciinema/asciinema), [local LLM PoC cast](https://asciinema.org/a/592283)
- [nushell/nushell](https://github.com/nushell/nushell), [awesome-nu](https://github.com/nushell/awesome-nu), [gpt2099.nu](https://github.com/cablehead/gpt2099.nu)
- [Aider issue #2742 — integrate wut for tmux last-error help](https://github.com/Aider-AI/aider/issues/2742)
- Our repo: [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](../../pitfalls/zsh-osc133-precmd-printf-a-not-stored.md)
