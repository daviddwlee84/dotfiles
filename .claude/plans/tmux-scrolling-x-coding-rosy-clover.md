# tmux Capture Helpers Extension: indexed blocks + agent pipe + TUI

## Context

Previous task (committed in `b5e8da0`) shipped `cpout` / `cpcmd` / `cpblock`
plus OSC 133 shell integration and tmux scrollback tuning. This extension
builds on that baseline:

1. **Indexed lookback** — currently the three helpers only grab the LAST
   block. Real debugging often wants "the one 3 commands back" (the error
   is usually not the last thing on screen). Add a positional `N` arg.
2. **One-shot pipe to coding-agent** — chaining `cpblock N` into `claude
   -p "fix this"` is a common-enough idiom to deserve its own command.
   User confirmed: **advisory only** by default (agent prints suggestion,
   doesn't touch files); **name `aifix` + `aiexplain`** (not `askai`).
3. **Interactive TUI** — a Python `uv run --script` tool that lets the
   user scroll previous commands, edit the prompt, and pick where the
   agent's reply goes (stdout / clipboard / interactive-agent-with-context).

Underlying mechanics are unchanged: OSC 133 markers in tmux's grid
line-attrs, navigated via `previous-prompt` / `previous-prompt -o`; the
agent is invoked in non-interactive mode (`claude -p`, `opencode run`,
`codex exec`, `cursor-agent -p`) with the block as context.

## Design decisions (confirmed with user)

- **Naming**: `aifix` (diagnose + suggest fix) and `aiexplain` (explain what
  happened). Two small fixed-purpose commands beat one `askai -m MODE`.
- **Agent mode**: **advisory only** — the default is print-only, no file
  edits. `--execute` / `--allow-edits` not offered in v1; escalation path
  is "spawn an interactive agent pane with this context" via the TUI.
- **Agent auto-detection**: `claude` → `opencode` → `codex` → `cursor-agent`,
  whichever is on `$PATH` first. Override via `-a AGENT`.
- **TUI library**: `questionary` + `rich` — matches
  [`scripts/init/dotfiles_init.py`](../../scripts/init/dotfiles_init.py)
  and [`scripts/fleet_apply.py`](../../scripts/fleet_apply.py). No new deps.
- **Script location**: `scripts/aiblock.py` (source of truth, agent-visible,
  matches `fleet_apply.py` convention); shell alias `aiblock` in
  `dot_config/zsh/tools/04_ai_capture.zsh` resolves the path via
  `chezmoi source-path` (cached once).

## Indexed lookback (shell-level)

### UX

```sh
cpblock          # last block (unchanged default)
cpblock 3        # block 3 back (third-to-last command + its output)
cpout 2          # output of the 2nd-to-last command
cpcmd 4          # input line of the 4th-to-last command
```

`N` is always "how many commands back, counting from the current prompt"
(1 = last, 2 = one before that, ...). No range/combine syntax in v1 —
that's the TUI's job.

### Implementation

**`dot_config/zsh/tools/03_tmux_capture.zsh`**: thread `N` through the
existing helper, ripple into the three public commands.

- `_cpx_tmux_select <name> <count> <start-cmd> [args]` — generalise the
  helper: `count` is how many `previous-*` repetitions before
  `begin-selection`, followed by a single `next-prompt` to close.
- `cpout [N]`: call helper with `count=N`, start=`previous-prompt -o`.
  (Because preexec skips C for cpout/cpcmd/cpblock, N=1 finds the PREVIOUS
  command's C, N=2 finds the one before that, etc.)
- `cpblock [N]`: call helper with `count=N+1`, start=`previous-prompt`.
  (The +1 skips cpblock's own A; the remaining N lands on the Nth block
  back's A.)
- `cpcmd [N]`: replace `fc -ln -1` with `fc -ln -N -N` (range from Nth
  back to Nth back — a single entry).

Validate `N` is a positive integer; default to `1`; reject `0` or negative
with stderr diagnostic.

## One-shot agent wrapper (shell-level)

### UX

```sh
aifix              # last block, default "diagnose + fix" prompt, auto-detected agent
aifix 3            # 3rd block back
aifix -a opencode  # force agent
aifix -p "why does this segfault?"  # override prompt
aiexplain          # same args, different default prompt
```

Defaults:

- **aifix prompt**: "Here is a command I ran in my terminal and its output.
  Diagnose any errors and suggest a concrete fix. Be brief and specific."
- **aiexplain prompt**: "Here is a command I ran in my terminal and its
  output. Explain what happened in plain language. Be concise."

### Implementation

**`dot_config/zsh/tools/04_ai_capture.zsh`** (new):

```zsh
_aiagent_invoke() {
  # Args: <agent> <prompt>
  # Invokes agent in non-interactive mode. prompt is sent via the agent's
  # one-shot flag; no file edits are requested.
  local agent=$1 prompt=$2
  case "$agent" in
    claude)       claude -p "$prompt" ;;
    opencode)     opencode run "$prompt" ;;
    codex)        codex exec "$prompt" ;;
    cursor-agent) cursor-agent -p "$prompt" ;;
    *) print -u2 "aifix: unknown agent: $agent"; return 1 ;;
  esac
}

_aiagent_autodetect() {
  for cand in claude opencode codex cursor-agent; do
    command -v "$cand" &>/dev/null && { print -r -- "$cand"; return 0; }
  done
  return 1
}

# aifix [N] [-a AGENT] [-p PROMPT]
aifix() { _ai_capture_dispatch aifix 'Diagnose any errors ...' "$@"; }
aiexplain() { _ai_capture_dispatch aiexplain 'Explain what happened ...' "$@"; }

_ai_capture_dispatch() {
  # parses N, -a, -p; calls cpblock $N; prepends prompt; invokes agent.
  # advisory only — no flag to enable edits in v1.
  ...
}
```

Output goes to stdout (pipe-friendly for `aifix | tee /tmp/advice.md`).
Diagnostic line to stderr ("aifix: claude invoked with 3rd block back").

### Call graph

```
aifix / aiexplain           <-- user types this
  → cpblock N               <-- reuses committed helper
  → _aiagent_invoke         <-- claude / opencode / codex / cursor-agent
```

## Python TUI

### UX sketch

```
$ aiblock
┌─ Recent commands (pick one) ──────────────────────────────────────┐
│ > 1  (45s ago)  cargo build --release                              │
│   2  (2m ago)   git rebase -i HEAD~5                               │
│   3  (4m ago)   pytest tests/integration/test_auth.py             │
│   4  (7m ago)   just fleet-apply                                   │
│   ...                                                              │
└───────────────────────────────────────────────────────────────────┘

[after selection, rich panel shows the captured block]

? Edit prompt (default: Diagnose any errors ...):
  [editable text box]

? Action:
  ▸ Print reply here (default)
    Copy reply to clipboard
    Spawn interactive agent pane with this context
    Cancel

[agent invoked, rich panel renders reply]
```

### Implementation

**`scripts/aiblock.py`** (new, PEP 723 shebang):

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["questionary>=2.0", "rich>=13.9"]
# ///
"""aiblock — TUI for reviewing a past command + asking an AI agent about it."""

import subprocess, os, sys, shlex
from rich.console import Console
from rich.panel import Panel
import questionary

def list_recent_commands(n=20):
    # zsh: `fc -ln -<n>` — last n commands; parse into (index, text)
    out = subprocess.run(["zsh", "-ic", f"fc -ln -{n}"],
                         capture_output=True, text=True).stdout
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return list(enumerate(reversed(lines), start=1))  # (N=1 is most recent)

def capture_block(n):
    # Delegate to our committed cpblock function
    return subprocess.run(["zsh", "-ic", f"cpblock {n}"],
                          capture_output=True, text=True).stdout

def invoke_agent(agent, prompt):
    # Mirror _aiagent_invoke logic from the shell wrapper
    flagmap = {"claude": ["-p"], "opencode": ["run"],
               "codex": ["exec"], "cursor-agent": ["-p"]}
    return subprocess.run([agent, *flagmap[agent], prompt],
                          capture_output=True, text=True).stdout

def main():
    # 1. pick command
    # 2. capture block, show preview in rich Panel
    # 3. questionary.text(default=DEFAULT_FIX_PROMPT) — editable
    # 4. questionary.select(actions) — Print / Copy / Spawn / Cancel
    # 5. invoke + route per action
    ...
```

Action routing:

- **Print reply**: write to stdout in a `rich.Panel`. User sees it in the
  same pane; scroll up to review. No clipboard.
- **Copy reply**: pipe reply through `tmux load-buffer -w -` when `$TMUX`
  set, else `pbcopy` / `xclip` / `xsel` / `wl-copy` (reuse the detection
  logic from `03_tmux_capture.zsh` `_cpx_to_clipboard`).
- **Spawn interactive agent pane**: build a command like `claude` (no
  `-p`) with the block pre-injected via a heredoc or temp-file, launch in
  a new tmux window with `tmux new-window -n ai 'claude <temp-file>'`.
  Concrete syntax TBD per agent; may need per-agent tweaks.
- **Cancel**: exit 0, no-op.

### Shell alias

**`dot_config/zsh/tools/04_ai_capture.zsh`** (same file as `aifix`):

```zsh
_AIBLOCK_SCRIPT=""
aiblock() {
  if [[ -z "$_AIBLOCK_SCRIPT" ]]; then
    local base
    base=$(chezmoi source-path 2>/dev/null) || {
      print -u2 "aiblock: chezmoi source-path failed"; return 1
    }
    _AIBLOCK_SCRIPT="$base/scripts/aiblock.py"
  fi
  uv run --script "$_AIBLOCK_SCRIPT" "$@"
}
```

Resolves once per shell (cached in `_AIBLOCK_SCRIPT`). `uv run --script`
handles dep install/cache.

## Files to modify

| Path | Change |
|---|---|
| `dot_config/zsh/tools/03_tmux_capture.zsh` | Thread `N` through `_cpx_tmux_select`; extend cpout/cpcmd/cpblock |
| `dot_config/zsh/tools/04_ai_capture.zsh` | **NEW** — aifix / aiexplain / aiblock (shell shim) + `_aiagent_*` helpers |
| `scripts/aiblock.py` | **NEW** — Python TUI |
| `docs/zsh/aliases.md` | Add rows under "Tmux Integration" + new "AI Capture" section |
| `docs/tools/tmux/README.md` | New section: "Reviewing past commands with AI agents" |

## Verification

End-to-end checks after apply:

1. **Indexed cpblock**: in a fresh tmux pane, run `echo A; echo B; echo C`
   as three separate commands. Then:
   ```sh
   cpblock     # should print "❯ echo C\nC"
   cpblock 2   # should print "❯ echo B\nB"
   cpblock 3   # should print "❯ echo A\nA"
   cpblock 99  # should print stderr "empty — …", exit 1
   ```
2. **cpout / cpcmd indexed**: same pattern, verify the right command's
   OUTPUT and INPUT come back.
3. **Agent auto-detect**: `aifix 1` in a pane where a command failed.
   Verify stderr logs which agent was picked; stdout has the agent's reply.
   Re-run with `-a opencode` / `-a codex` and verify override.
4. **Agent override**: `aifix -p "custom prompt" 2` verifies both overrides
   compose.
5. **aiblock TUI**: run `aiblock` in a tmux pane after 5+ commands. Confirm:
   (a) recent commands list shows correct N (from `fc`);
   (b) selecting one shows the block in a rich Panel;
   (c) prompt editor has the aifix default;
   (d) each action (Print / Copy / Spawn / Cancel) routes correctly.
6. **Graceful degradation**: `aifix` in a non-tmux shell → stderr error
   from cpblock (inherits existing behaviour); exit 1.
7. **No-agent-installed**: `aifix` with no CLI on PATH → stderr "no
   coding-agent CLI found (tried: claude, opencode, codex, cursor-agent)";
   exit 1.

## Critical files found during exploration

- [`dot_config/zsh/tools/42_gitlab.zsh:100-103`](../../dot_config/zsh/tools/42_gitlab.zsh) —
  canonical non-interactive agent invocation map; reuse the exact
  flag syntax (`claude -p`, `opencode run`, `codex exec`,
  `cursor-agent -p`).
- [`dot_config/zsh/tools/03_tmux_capture.zsh`](../../dot_config/zsh/tools/03_tmux_capture.zsh) —
  committed baseline; `_cpx_tmux_select` and `_cpx_to_clipboard` helpers
  to extend / reuse.
- [`scripts/init/dotfiles_init.py`](../../scripts/init/dotfiles_init.py) —
  questionary + rich + tyro pattern to mirror in `aiblock.py`.
- [`scripts/fleet_apply.py`](../../scripts/fleet_apply.py) — same stack;
  good reference for subprocess + rich.live patterns if we want progress
  UI while the agent is thinking.
- [`dot_config/zsh/tools/22_sesh.zsh:92-115`](../../dot_config/zsh/tools/22_sesh.zsh) —
  `_sesh_wrap_agent` pattern for spawning an interactive agent pane; copy
  the shape for "Spawn agent with this context" action in the TUI.
