#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "questionary>=2.0",
#     "rich>=13.9",
# ]
# ///
"""aiblock — pick recent shell command(s), edit a prompt, send to a coding-agent.

UI is a short sequence of questionary prompts + rich panels:
  1. Pick one or more recent commands (checkbox; Space toggles, Enter confirms).
     Skipping the selection defaults to "last block".
  2. Preview the captured block(s). Multi-select concats them in chronological
     order (oldest first) with "--- Block -N ---" separators so the agent
     can tell the turns apart.
  3. Edit the prompt (default: "diagnose + fix").
  4. Choose an action: print reply / copy / spawn interactive agent / cancel.

Advisory-only: agent is invoked with its one-shot flag so replies are text,
no auto-edits. To iterate further with the context pre-loaded, pick the
"Spawn interactive agent" action.

Depends on:
  - dot_config/zsh/tools/02_shell_integration.zsh (OSC 133 markers)
  - dot_config/zsh/tools/03_tmux_capture.zsh (cpblock)
  - dot_config/zsh/tools/04_ai_capture.zsh (aiblock() wrapper dumps history)
  - zsh on PATH (wrapper runs `fc -ln -30` in the caller's shell)
  - tmux (we run inside a pane)
  - at least one of: claude / opencode / codex / cursor-agent
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass

import json
import questionary
from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel

DEFAULT_FIX_PROMPT = (
    "Here is a command I ran in my terminal and its output. "
    "Diagnose any errors and suggest a concrete fix. Be brief and specific."
)

# Env-var defaults mirror 04_ai_capture.zsh. If the shell has exported
# AICAP_*, os.environ picks them up; otherwise these defaults kick in.
AICAP_CLAUDE_MODEL = os.environ.get("AICAP_CLAUDE_MODEL", "haiku")
AICAP_OPENCODE_MODEL = os.environ.get("AICAP_OPENCODE_MODEL", "github-copilot/claude-haiku-4.5")
AICAP_CODEX_MODEL = os.environ.get("AICAP_CODEX_MODEL", "gpt-5-mini")
AICAP_CURSOR_MODEL = os.environ.get("AICAP_CURSOR_MODEL", "")
AICAP_SHOW_METADATA = os.environ.get("AICAP_SHOW_METADATA", "1") == "1"
AICAP_PRETTIFY = os.environ.get("AICAP_PRETTIFY", "1") == "1"

# Each agent's non-interactive invocation args (model-aware). The Claude
# entry is special-cased in invoke_agent_oneshot because we optionally
# use --output-format json for metadata extraction.
AGENT_CONFIG = {
    "claude":       {"base": ["claude", "-p", "--model", AICAP_CLAUDE_MODEL]},
    "opencode":     {"base": ["opencode", "run", "-m", AICAP_OPENCODE_MODEL]},
    "codex":        {"base": ["codex", "exec", "-m", AICAP_CODEX_MODEL]},
    "cursor-agent": {"base": ["cursor-agent", "-p"] + (["--model", AICAP_CURSOR_MODEL] if AICAP_CURSOR_MODEL else [])},
}

console = Console(stderr=False)


@dataclass
class HistoryEntry:
    n: int          # 1-based index: 1 = most recent
    command: str    # the command text


def detect_agents() -> list[str]:
    """Return the subset of known agents found on PATH, in preference order."""
    return [a for a in AGENT_CONFIG if shutil.which(a)]


def zsh_run(code: str, timeout: float = 5.0) -> str:
    """Run `zsh -ic CODE` and return stdout (strip trailing newline).

    -ic is needed so our zsh config loads (sourcing 03_tmux_capture.zsh etc.).
    """
    # $ZDOTDIR is set by chezmoi's 00_exports; pass-through so an interactive
    # zsh finds the user's rc. Inherits TMUX so cpblock sees the right pane.
    result = subprocess.run(
        ["zsh", "-ic", code],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=os.environ,
    )
    return result.stdout.rstrip("\n")


def list_recent_commands(n: int = 20) -> list[HistoryEntry]:
    """Return the last `n` shell commands as HistoryEntry(N, cmd).

    Reads $AIBLOCK_HIST_DUMP (written by the zsh `aiblock` wrapper via
    `fc -ln -30`) — a `zsh -ic fc …` subshell does NOT see the current
    shell's in-memory history, and `fc -R` from HISTFILE misses commands
    that haven't been flushed yet. The env-passed dump is the only
    reliable source for "what did the USER just run".

    Falls back to parsing $HISTFILE directly if the dump env var isn't
    set (e.g. someone ran the script without the wrapper).

    Returned list is ordered most-recent-first, with `.n` matching what
    cpblock/cpcmd/cpout expect as their positional N arg.
    """
    dump_path = os.environ.get("AIBLOCK_HIST_DUMP")
    lines: list[str] = []
    if dump_path and os.path.isfile(dump_path):
        with open(dump_path, encoding="utf-8", errors="replace") as f:
            lines = [ln.strip() for ln in f if ln.strip()]
    else:
        # Fallback: parse HISTFILE directly.
        histfile = os.environ.get("HISTFILE") or os.path.expanduser("~/.zsh_history")
        if os.path.isfile(histfile):
            with open(histfile, encoding="latin-1", errors="replace") as f:
                raw = f.readlines()
            for raw_ln in raw[-n * 3:]:  # last 3N raw lines (covers line continuations)
                s = raw_ln.rstrip("\n").strip()
                if not s:
                    continue
                # EXTENDED_HISTORY format: ": TIMESTAMP:DURATION;CMD"
                if s.startswith(": "):
                    parts = s.split(";", 1)
                    if len(parts) == 2:
                        s = parts[1]
                lines.append(s)
    # Take the last n, reverse so index 1 == most recent.
    lines = lines[-n:]
    return [HistoryEntry(n=i, command=cmd) for i, cmd in enumerate(reversed(lines), start=1)]


def capture_block(n: int) -> str:
    """Return cpblock N's stdout."""
    return zsh_run(f"cpblock {n}", timeout=10.0)


def invoke_agent_oneshot(agent: str, prompt: str) -> tuple[str, dict]:
    """Invoke an agent in non-interactive mode; return (reply_text, metadata).

    For Claude, we request --output-format json so we can pull usage/cost
    into the metadata dict. Other agents fall back to text output with a
    minimal metadata dict containing just the model name.
    """
    base = AGENT_CONFIG[agent]["base"]
    meta: dict = {"agent": agent, "model": _model_for(agent)}

    if agent == "claude" and AICAP_SHOW_METADATA:
        result = subprocess.run(
            [*base, "--output-format", "json", prompt],
            capture_output=True,
            text=True,
            timeout=180.0,
        )
        if result.returncode != 0:
            console.print(f"[red]{agent} exited {result.returncode}[/red]")
            if result.stderr:
                console.print(f"[dim]{result.stderr}[/dim]")
            return "", meta
        try:
            parsed = json.loads(result.stdout)
            # Claude's JSON has no top-level `.model`; the actual model name
            # lives as the single key of `.modelUsage`.
            mu = parsed.get("modelUsage") or {}
            if mu:
                meta["model"] = next(iter(mu.keys()))
            usage = parsed.get("usage", {})
            meta["input_tokens"] = usage.get("input_tokens")
            meta["output_tokens"] = usage.get("output_tokens")
            meta["cache_read"] = usage.get("cache_read_input_tokens") or 0
            meta["cache_create"] = usage.get("cache_creation_input_tokens") or 0
            meta["cost_usd"] = parsed.get("total_cost_usd")
            meta["duration_ms"] = parsed.get("duration_ms")
            return parsed.get("result", ""), meta
        except json.JSONDecodeError:
            return result.stdout, meta  # fall back to raw

    result = subprocess.run(
        [*base, prompt],
        capture_output=True,
        text=True,
        timeout=180.0,
    )
    if result.returncode != 0:
        console.print(f"[red]{agent} exited {result.returncode}[/red]")
        if result.stderr:
            console.print(f"[dim]{result.stderr}[/dim]")
    return result.stdout, meta


def _model_for(agent: str) -> str:
    return {
        "claude": AICAP_CLAUDE_MODEL,
        "opencode": AICAP_OPENCODE_MODEL,
        "codex": AICAP_CODEX_MODEL,
        "cursor-agent": AICAP_CURSOR_MODEL or "(default)",
    }[agent]


def format_metadata(meta: dict) -> str:
    """Single-line metadata summary for stderr / panel subtitle."""
    parts = [f"{meta['agent']} ({meta['model']})"]
    if meta.get("input_tokens") is not None:
        parts.append(f"in={meta['input_tokens']}")
    if meta.get("output_tokens") is not None:
        parts.append(f"out={meta['output_tokens']}")
    if meta.get("cache_read") or meta.get("cache_create"):
        parts.append(f"cache=(r:{meta.get('cache_read', 0)},w:{meta.get('cache_create', 0)})")
    if meta.get("cost_usd") is not None:
        parts.append(f"cost=${meta['cost_usd']}")
    if meta.get("duration_ms") is not None:
        parts.append(f"{meta['duration_ms']}ms")
    return " | ".join(parts)


def copy_to_clipboard(text: str) -> bool:
    """Write text to the system clipboard. Mirror of _cpx_to_clipboard in zsh."""
    if os.environ.get("TMUX"):
        proc = subprocess.run(["tmux", "load-buffer", "-w", "-"], input=text, text=True)
        return proc.returncode == 0
    for cmd in [["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard", "-in"], ["xsel", "--clipboard", "--input"]]:
        if shutil.which(cmd[0]):
            proc = subprocess.run(cmd, input=text, text=True)
            return proc.returncode == 0
    return False


def spawn_interactive_agent(agent: str, context: str, prompt: str) -> None:
    """Open a new tmux window running `agent` with block + prompt pre-loaded.

    Implementation: write context+prompt to a temp file, start the agent in a
    new tmux window with a shell that cats the file to the agent's stdin,
    then execs the interactive agent. This gives the user an ongoing session
    seeded with the context.
    """
    if not os.environ.get("TMUX"):
        console.print("[red]Spawn requires tmux.[/red]")
        return
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".txt") as f:
        f.write(prompt + "\n\n" + context + "\n")
        ctx_file = f.name
    # Build an appropriate interactive invocation per agent. This is
    # best-effort — agents vary in how they accept piped context. The
    # common pattern: paste context into the first user message, then
    # continue interactively.
    # For now, launch the agent plain in a new window and drop the context
    # file path into the window title so the user can paste it with Enter.
    title = f"ai:{agent}"
    # Try to pre-paste context via tmux paste-buffer: load the file into a
    # named buffer, start the agent, then paste the buffer.
    subprocess.run(["tmux", "load-buffer", "-b", "aiblock", ctx_file])
    subprocess.run([
        "tmux", "new-window", "-n", title,
        f"{agent}; rm -f {ctx_file}",
    ])
    console.print(
        f"[green]Opened new tmux window '{title}' running {agent}.[/green]\n"
        f"[dim]Context in tmux paste-buffer 'aiblock' — "
        f"press `prefix + =` to choose it, or `tmux paste-buffer -b aiblock`.[/dim]"
    )


def main() -> int:
    if "--help" in sys.argv or "-h" in sys.argv:
        console.print(__doc__)
        return 0

    if not os.environ.get("TMUX"):
        console.print("[red]aiblock must run inside a tmux pane (uses cpblock).[/red]")
        return 1

    agents = detect_agents()
    if not agents:
        console.print(
            "[red]No coding-agent CLI on PATH.[/red]\n"
            "[dim]Install one of: claude, opencode, codex, cursor-agent.[/dim]"
        )
        return 1

    history = list_recent_commands(n=20)
    if not history:
        console.print("[red]Shell history is empty — no commands to pick from.[/red]")
        return 1

    # 1. Pick one or more commands (multi-select via checkbox).
    # Space toggles, Enter accepts; picking zero falls back to "last block".
    choices = [
        questionary.Choice(
            title=f"{h.n:>2}  {h.command[:100]}",
            value=h.n,
        )
        for h in history
    ]
    picked = questionary.checkbox(
        "Pick command(s) to review (Space toggles, Enter confirms):",
        choices=choices,
        qmark="▸",
    ).ask()
    if picked is None:
        return 1
    if not picked:
        picked = [1]  # default to most recent

    # Sort descending so the OLDEST-first chronological order when we iterate
    # (N=5 is older than N=1; we want history-order concat).
    picked_ns = sorted(set(picked), reverse=True)

    # 2. Capture each block + show a combined preview. Concat with separators
    # so the agent can see boundaries.
    blocks: list[tuple[int, str]] = []
    for n in picked_ns:
        text = capture_block(n)
        if not text.strip():
            console.print(
                f"[yellow]cpblock {n} returned empty — skipping.[/yellow]"
            )
            continue
        blocks.append((n, text.rstrip()))
    if not blocks:
        console.print(
            "[red]All selected blocks were empty.[/red]\n"
            "[dim]Try `exec zsh` if the shell pre-dates chezmoi apply, "
            "or pick different indices.[/dim]"
        )
        return 1

    # Single-block: preserve the original Panel shape. Multi-block: show each
    # in its own Panel so boundaries are obvious before the user commits.
    if len(blocks) == 1:
        n, text = blocks[0]
        console.print(Panel(text, title=f"Block -{n}", expand=False))
        block = text
    else:
        for n, text in blocks:
            console.print(Panel(text, title=f"Block -{n}", expand=False))
        # Agent sees: --- Block -5 ---\n<text>\n\n--- Block -3 ---\n<text>
        # Picking a clear separator helps the model know these are distinct
        # turns rather than one long transcript.
        block = "\n\n".join(
            f"--- Block -{n} ---\n{text}" for n, text in blocks
        )

    # 3. Edit the prompt
    prompt = questionary.text(
        "Prompt (edit or accept):",
        default=DEFAULT_FIX_PROMPT,
        multiline=True,
    ).ask()
    if prompt is None:
        return 1

    # 4. Choose agent if multiple available
    if len(agents) > 1:
        agent = questionary.select(
            "Agent:",
            choices=agents,
            default=agents[0],
        ).ask()
        if agent is None:
            return 1
    else:
        agent = agents[0]

    # 5. Choose action
    action = questionary.select(
        "Action:",
        choices=[
            questionary.Choice("Print reply here", value="print"),
            questionary.Choice("Copy reply to clipboard", value="copy"),
            questionary.Choice(f"Spawn new tmux window running {agent} with context", value="spawn"),
            questionary.Choice("Cancel", value="cancel"),
        ],
    ).ask()
    if action in (None, "cancel"):
        return 0

    full_prompt = f"{prompt}\n\n{block}"

    if action == "spawn":
        spawn_interactive_agent(agent, block, prompt)
        return 0

    # Print / Copy both need the agent to actually reply
    with console.status(f"[cyan]Asking {_model_for(agent)}…[/cyan]", spinner="dots"):
        reply, meta = invoke_agent_oneshot(agent, full_prompt)

    if not reply.strip():
        console.print("[yellow]Agent returned empty reply.[/yellow]")
        return 1

    subtitle = format_metadata(meta) if AICAP_SHOW_METADATA else None

    if action == "print":
        # Render markdown so headings / code fences / lists look right.
        if AICAP_PRETTIFY:
            console.print(
                Panel(
                    Markdown(reply.rstrip()),
                    title=f"{agent} reply",
                    subtitle=subtitle,
                    expand=False,
                )
            )
        else:
            console.print(
                Panel(reply.rstrip(), title=f"{agent} reply", subtitle=subtitle, expand=False)
            )
    elif action == "copy":
        ok = copy_to_clipboard(reply)
        if ok:
            msg = f"[green]Copied {len(reply)} bytes to clipboard.[/green]"
            if subtitle:
                msg += f"\n[dim]{subtitle}[/dim]"
            console.print(msg)
        else:
            console.print("[red]No clipboard tool available.[/red]")
            return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
