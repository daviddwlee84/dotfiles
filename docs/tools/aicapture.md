# aicapture — AI review of past shell commands

Capture a past shell command's block from tmux scrollback, pipe it to a coding-agent CLI (Claude Code / OpenCode / Codex / Cursor Agent) in non-interactive mode, get back a fix or explanation. Advisory by default: agent prints suggestions, doesn't touch files.

Built on [OSC 133 semantic prompts](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md) — the shell emits `A`/`C`/`D` line-attribute markers, tmux stores them, our helpers navigate by them. For background on how this compares to `thefuck`, Warp, `wut`, `tmuxai`, `atuin`, etc., see [instant-llm-fix-prior-art.md](../this_repo/instant-llm-fix-prior-art.md).

> **Why not Charm [`mods`](https://github.com/charmbracelet/mods)?** `mods` is a generic CLI LLM client. We deliberately route through the existing agent CLIs (Claude Code / OpenCode / Codex / Cursor Agent) instead, because they own the per-tool model selection, system prompts, tool permissions, and project context that `aifix` / `aiexplain` rely on. `aicapture` is a tmux-scrollback capture layer, not a model-routing layer; the agent CLIs already handle the routing. Auto-detection chain lives in `dot_config/zsh/tools/04_ai_capture.zsh`.

## Quick start

```sh
# Any command that produced useful output or an error…
cargo build --release

# …is one keystroke away from a diagnose + fix:
aifix
```

Output in your terminal:

```
aifix ← block -1
⠋ claude haiku (json)…                                  # spinner while agent thinks
claude (claude-haiku-4-5-20251001) | in=12 out=87 cache=(r:24402,w:12487) | cost=$0.0008 3812ms

## Fix for `cargo build` error

Your `Cargo.toml` is missing the `serde` dependency. Add:

    [dependencies]
    serde = { version = "1.0", features = ["derive"] }

Then re-run `cargo build --release`.
```

Reply is rendered as Markdown via `glow` (auto-falls back to `bat --language=md`, then raw text if neither is installed).

## Commands

### Capture (no AI call)

Each prints captured text to stdout (pipe-friendly) **and** copies it to the system clipboard via tmux's OSC 52 bridge (works over SSH). Defaults to N=1 (most recent); pass a positive integer for N-back lookback.

| Command | Scope |
|---|---|
| `cpcmd [N]` | Nth-latest command's **input line** (from zsh history — works outside tmux too) |
| `cpout [N]` | Nth-latest command's **output** only (via tmux + OSC 133) |
| `cpblock [N]` | Nth-latest command's **full block**: prompt + input + output (Warp-style) |

```sh
cpblock                          # last block → clipboard + stdout
cpblock 3                        # 3rd-latest
cpout 2 | tee /tmp/snapshot.log  # pipe output to file while also copying
cpcmd                            # just the command string (no output)
```

### AI review

Same positional `[N]` as the capture helpers, plus flags:

| Command | Default prompt |
|---|---|
| `aifix [N]` | *"Diagnose any errors and suggest a concrete fix. Be brief and specific."* |
| `aiexplain [N]` | *"Explain what happened in plain language. Be concise."* |

Both accept:

- `-a AGENT` — `claude` / `opencode` / `codex` / `cursor-agent` / `http`. Default: auto-detect (first one found on `$PATH`; `http` is opt-in, see [Provider routing](#provider-routing-openrouter--ollama)).
- `-p PROMPT` — override the default prompt.
- `--raw` — skip glow/bat prettify; print the agent's raw Markdown text.
- `--no-meta` — suppress the stderr metadata line (model / tokens / cost / duration).
- `-h` / `--help` — print the full signature and current env-var values.

```sh
aifix                               # last block, default fix prompt
aifix 3 -a opencode                 # 3rd-latest, force OpenCode
aifix -p "is this safe on prod?"    # custom prompt
aiexplain 2 --raw                   # no prettify
aifix --no-meta | tee /tmp/ans.md   # pipe-friendly
```

### Interactive TUI

```sh
aiblock
```

Launches a [questionary](https://github.com/tmbo/questionary) + [rich](https://github.com/Textualize/rich) TUI ([`scripts/aiblock.py`](../../scripts/aiblock.py)) that walks through:

1. **Checkbox picker** over the last 20 commands. Space toggles, Enter confirms. Picking none defaults to "last block".
2. **Preview** — each selected block shown in its own rich panel (multi-select concatenates in chronological order with `--- Block -N ---` separators so the agent can tell the turns apart).
3. **Prompt edit** — default is the `aifix` fix-prompt; edit inline.
4. **Action** — one of:
   - *Print reply here* — rendered as Markdown in a rich panel with the metadata as subtitle.
   - *Copy reply to clipboard* — via tmux OSC 52 / pbcopy / xclip / xsel / wl-copy.
   - *Spawn new tmux window running `<agent>`* — opens a fresh interactive agent session with your selected blocks pre-loaded into tmux's `aiblock` paste-buffer. Pull via `prefix + =`.

The TUI depends on `uv` (PEP 723 inline deps) — no separate install step required; first run populates the uv cache.

## Non-tmux alternatives

When you're not in tmux (VSCode integrated terminal, bare Ghostty without tmux, quick SSH session), `cpblock` / `aifix` / `aiexplain` / `aiblock` can't see scrollback — they depend on tmux's OSC 133 line attributes. Three Tier 1 wrappers cover the common cases without magic (no shell hooks, no PTY proxy, no `script(1)` wrapping — see [`backlog/ai-capture-non-tmux-output.md`](../../backlog/ai-capture-non-tmux-output.md) for why we reject those paths):

| Command | Source of context | Typical use |
|---|---|---|
| `aifix-stdin` | whatever you pipe in | `tail -100 build.log \| aifix-stdin` |
| `aifix-run -- CMD [ARG...]` | runs `CMD`, tees stdout+stderr to a log, reviews | `aifix-run -- cargo build --release` |
| `aifix-rerun` | re-executes the previous shell command (confirm prompt) | `aifix-rerun` after a transient error |

All three accept the same flags as `aifix` (`-a AGENT` / `-p PROMPT` / `--raw` / `--no-meta`). `aifix-rerun` adds `-y` to skip the "⚠ side effects" confirmation. Default prompt for each is the `aifix` "diagnose + fix"; use `-p "explain what happened"` if you want the explain behaviour.

```sh
# stdin — compose with any producer
tail -200 /var/log/nginx/error.log | aifix-stdin
curl -sS https://weird.api/thing | aifix-stdin -p "what is this JSON telling me?"
aifix-stdin < /tmp/build-fail.log

# run — capture a fresh invocation (double-run safe, no prior history needed)
aifix-run -- ls /missing
aifix-run -p "is this safe on prod?" -- ansible-playbook deploy.yml

# rerun — thefuck-style, re-execute last cmd. Confirms by default.
mvn compile      # fails
aifix-rerun      # "⚠ side effects…  Proceed? [y/N]"
aifix-rerun -y   # skip confirm
```

**isatty caveat** for `aifix-run`: teeing makes CMD's stdout a pipe, so TUI apps (vim, less, htop) render in degraded mode. Don't `aifix-run` an interactive tool — pipe its log file via `aifix-stdin` after the fact instead.

**Side-effect warning** for `aifix-rerun`: re-running `rm`, `curl -X POST`, `git push`, migrations, etc. is dangerous. The confirmation prompt is there for a reason; don't `-y` without reading what will be re-executed.

## Configuration

Put any of these in `~/.zshrc`, a `99_local_*.zsh` override, or export them per-session:

```sh
# Pin an agent (otherwise auto-detect: claude → opencode → codex → cursor-agent)
export AICAP_AGENT=                                           # empty = auto-detect; set to claude|opencode|codex|cursor-agent|http to force

# Model per agent
export AICAP_CLAUDE_MODEL=haiku                              # alias or full name (e.g. claude-sonnet-4-6)
export AICAP_OPENCODE_MODEL=github-copilot/claude-haiku-4.5  # provider/model format
export AICAP_CODEX_MODEL=gpt-5-mini
export AICAP_CURSOR_MODEL=                                    # empty = cursor-agent picks

# Output behaviour
export AICAP_SHOW_METADATA=1   # 0 to mute the stderr "claude (...) | in=... cost=..." line
export AICAP_PRETTIFY=1        # 0 to always print raw Markdown (skip glow/bat)
export AICAP_SPINNER=1         # 0 to disable the stderr spinner animation
```

### Provider routing: OpenRouter / Ollama

The `http` agent talks an OpenAI-compatible chat-completions endpoint directly via `curl` + `jq` — no agent CLI required. The same code path handles **OpenRouter free models** (Bearer key) and **local Ollama** (no auth) since both speak the same schema. `http` is never auto-detected; opt in with `AICAP_AGENT=http` or `-a http`.

```sh
# OpenRouter — free Gemini Flash, ~5s round-trip, requires a (free) account
export OPENROUTER_API_KEY=sk-or-v1-...
export AICAP_AGENT=http
# defaults already point at OpenRouter + Gemini Flash free; no other vars needed
aifix
# Switch model:
AICAP_HTTP_MODEL=meta-llama/llama-3.3-70b-instruct:free aifix

# Ollama — fully offline / privacy-sensitive
ollama serve &                          # or `brew services start ollama`
ollama pull qwen2.5-coder:7b
export AICAP_AGENT=http
export AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions
export AICAP_HTTP_MODEL=qwen2.5-coder:7b
aifix
```

Per-call override (no exports needed):

```sh
AICAP_AGENT=http AICAP_HTTP_MODEL=google/gemini-2.0-flash-exp:free aifix 3
```

Tunables:

| Var | Default | Notes |
|---|---|---|
| `AICAP_HTTP_URL` | `https://openrouter.ai/api/v1/chat/completions` | Full chat-completions URL. Ollama's is `http://localhost:11434/v1/chat/completions`. |
| `AICAP_HTTP_MODEL` | `google/gemini-2.0-flash-exp:free` | Provider-specific model name. |
| `AICAP_HTTP_API_KEY` | `${OPENROUTER_API_KEY:-}` | Bearer token. Empty = no `Authorization` header (Ollama). |

The `http` agent has the same metadata line shape as the others (`http (model @ host) | in=N out=N`) and reuses the same spinner / prettify / `--raw` / `--no-meta` plumbing. Errors are surfaced verbatim from `.error.message` in the JSON response.

> **Why not just use opencode?** OpenCode supports `openrouter/...` and `ollama/...` model strings natively. If you already have opencode installed, `AICAP_OPENCODE_MODEL=ollama/qwen2.5-coder:7b aifix -a opencode` works and is supported. The `http` agent is for hosts where no CLI is installed (minimal SSH boxes, CI runners) and for users who prefer one less moving part.

Check current settings any time with `aifix --help`.

Defaults are tuned for Haiku-class models — fast (~5s round-trip) and cheap (~$0.001/call with cache hits). If you want Opus/Sonnet for harder diagnoses, set `AICAP_CLAUDE_MODEL=sonnet` either globally or per-invocation:

```sh
AICAP_CLAUDE_MODEL=sonnet aifix 3
```

## Maintaining the agent list (SSOT + its four consumers)

[`dot_config/shell/04_ai_agents.sh`](../../dot_config/shell/04_ai_agents.sh) is the
**single source of truth** for the agent autodetect order and the
`AICAP_<AGENT>_MODEL` defaults. Edit that file and nothing else for a default
change — but be aware it has four *non-shell* consumers that **regex-parse the
same file** because they run in cron / tmux-popup contexts where the shell
environment isn't inherited:

| Consumer | Why it can't just read the env |
|---|---|
| `dot_config/tmux/executable_tmux-session-summary.py` | tmux popup, no interactive shell |
| `scripts/aiblock.py` | spawned by the TUI |
| `dot_dotfiles/bin/executable_pqsum` | invoked over SSH by `fleet pueue` |
| `scripts/fleet/exec.py` | invoked over SSH by `fleet exec` |

Each agent's `-m` / `--model` flag is emitted **only** when its variable is
non-empty, so a retired model ID falls through to the CLI's own default instead
of hard-failing.

Adding a **new agent** means touching all six places: one `AICAP_<AGENT>_MODEL`
line in the SSOT, the `_aiagent_invoke` case in
`dot_config/shell/04_ai_capture.sh`, and the `AGENT_CONFIG` dict in each of the
four Python consumers above.

!!! note "Four consumers is the pain threshold"

    The duplication is already past comfortable. The queued fix is to extract a
    shared `scripts/aisum/__init__.py` parser; land that refactor before adding
    a fifth callsite rather than after.

## Requirements

| What | For |
|---|---|
| `zsh` | All commands (cpcmd, aifix, etc. are zsh functions) |
| `tmux 3.3+` | `cpout` / `cpblock` / `aifix` / `aiexplain` / `aiblock` (scrollback navigation) |
| OSC 133 shell integration | The hook in `dot_config/zsh/tools/02_shell_integration.zsh` emits the A/C/D markers tmux needs. Run `exec zsh` after install so the hook fires in your current shell. |
| At least one coding-agent CLI | `claude` (recommended), `opencode`, `codex`, or `cursor-agent` — install via your usual channel |
| `glow` (optional) | Markdown prettify on agent replies |
| `bat` (optional) | Prettify fallback when `glow` isn't present |
| `jq` (optional) | Parses Claude's `--output-format json` for the metadata line (tokens / cost). Required (not optional) when using the `http` agent. |
| `curl` | Required when using the `http` agent (OpenRouter / Ollama). Universally present on macOS / Linux. |
| `uv` (optional) | Needed only for the `aiblock` TUI — installs its Python deps lazily |

## Standalone setup (no chezmoi)

If you don't want to adopt the whole dotfiles repo, grab these four files and source them from your `~/.zshrc`. They're self-contained apart from the listed optional tools above.

```sh
REPO=https://raw.githubusercontent.com/daviddwlee84/dotfiles/main
mkdir -p ~/.config/zsh/tools

# Shell side: OSC 133 hook + cpblock family + aifix family
for f in 02_shell_integration.zsh 03_tmux_capture.zsh 04_ai_capture.zsh; do
  curl -fsSL "$REPO/dot_config/zsh/tools/$f" -o "$HOME/.config/zsh/tools/$f"
done

# Optional TUI (needs uv)
mkdir -p ~/.local/share/aicapture
curl -fsSL "$REPO/scripts/aiblock.py" -o ~/.local/share/aicapture/aiblock.py
chmod +x ~/.local/share/aicapture/aiblock.py

# Append to ~/.zshrc (or equivalent)
cat >> ~/.zshrc <<'EOF'
for f in ~/.config/zsh/tools/02_shell_integration.zsh \
         ~/.config/zsh/tools/03_tmux_capture.zsh \
         ~/.config/zsh/tools/04_ai_capture.zsh; do
  [[ -r "$f" ]] && source "$f"
done
EOF

# Reload
exec zsh
```

The `aiblock` shell function resolves the TUI path via `chezmoi source-path`; if you're not on chezmoi, edit the `aiblock()` function in `04_ai_capture.zsh` to point at `~/.local/share/aicapture/aiblock.py` instead:

```zsh
# replace the chezmoi source-path block with:
_AIBLOCK_SCRIPT="$HOME/.local/share/aicapture/aiblock.py"
```

### Read source on GitHub

- [`dot_config/zsh/tools/02_shell_integration.zsh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/zsh/tools/02_shell_integration.zsh) — OSC 133 precmd/preexec hooks (A marker embedded in `$PROMPT` via `%{...%}` — see [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-osc133-precmd-printf-a-not-stored.md) for why)
- [`dot_config/zsh/tools/03_tmux_capture.zsh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/zsh/tools/03_tmux_capture.zsh) — cpout / cpcmd / cpblock + tmux copy-mode chain helpers
- [`dot_config/zsh/tools/04_ai_capture.zsh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/zsh/tools/04_ai_capture.zsh) — aifix / aiexplain / aiblock wrappers, agent dispatch, spinner
- [`scripts/aiblock.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/aiblock.py) — Python TUI (PEP 723 inline deps)

## Troubleshooting

### `cpblock returned empty` / `aifix ← block -1` then nothing

Your current shell was started before the hook was installed. The precmd/preexec hooks that emit OSC 133 markers need to be registered via `add-zsh-hook`, which only happens when `02_shell_integration.zsh` is sourced. Fix:

```sh
exec zsh                                             # reload shell in place
echo $precmd_functions | tr ' ' '\n' | grep osc133   # verify
# expected: _osc133_precmd
```

If `exec zsh` doesn't help, open a fresh tmux window — some terminal states don't propagate cleanly through `exec`.

### `aiblock`: "Shell history is empty — no commands to pick from"

Should no longer happen after commit `3993b7b`. If it does, the zsh wrapper that dumps history via `fc -ln -30` isn't running. Verify:

```sh
which aiblock     # should show the function from 04_ai_capture.zsh
type aiblock      # should show the fc-dump logic
```

Workaround: the TUI also falls back to parsing `$HISTFILE` directly, so `HISTFILE=~/.zsh_history aiblock` works even if the wrapper is broken.

### Metadata line shows `claude (?)` instead of the model

`jq` failed to find `.modelUsage | keys | first` in Claude's JSON output. Either `jq` is out of date (install latest) or Claude CLI changed its JSON shape. Set `AICAP_SHOW_METADATA=0` to bypass until fixed.

### Spinner doesn't appear / doesn't disappear

Spinner auto-skips when stderr isn't a tty. If you're redirecting with `2>/tmp/err` or piping through `tee` you won't see it — by design.

If the spinner leaves a stale `⠋ ...` line after the agent returns, the `kill $_AICAP_SPIN_PID` + `\r\e[K` cleanup didn't run (usually because of a signal during a subshell). Press `Ctrl+L` to redraw, then report it.

### tmux scrollback looks "broken" / ghost frames

Not directly an aicapture issue but adjacent — see [`pitfalls/tmux-scrollback-tui-repaint-ghosting.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-scrollback-tui-repaint-ghosting.md) and the `scroll-on-clear off` + `prefix + [` workflow.

## Related

- [`docs/tools/tmux/README.md`](tmux/README.md) — tmux configuration, the OSC 133 protocol deep-dive, copy-mode bindings (`prefix + M-y` / `M-i` / `{` / `}` / `M-[` / `M-]`)
- [`docs/this_repo/instant-llm-fix-prior-art.md`](../this_repo/instant-llm-fix-prior-art.md) — how this layer compares to `thefuck` (rule-based, drifting), `shell_gpt`/`aichat`/`ai-shell` (NL→command, not the same problem), `wut`/`tmuxai` (tmux peers), `butterfish`/Warp (PTY proxy), `atuin` (history DB), and the OSC 133 terminals (Ghostty/WezTerm/Kitty/iTerm2)
- [`pitfalls/zsh-osc133-precmd-printf-a-not-stored.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-osc133-precmd-printf-a-not-stored.md) — the ZLE timing trap that forced the `$PROMPT`-embedded A marker workaround
- [`docs/shells/aliases.md`](../shells/aliases.md) — the repo's full custom-alias index (cpcmd/cpout/cpblock/aifix/aiexplain/aiblock live under "Tmux Integration" and "AI Capture")
