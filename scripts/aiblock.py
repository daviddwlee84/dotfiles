#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "questionary>=2.0",
#     "rich>=13.9",
# ]
# ///
"""aiblock — pick a recent shell command, edit a prompt, send to a coding-agent.

UI is a short sequence of questionary prompts + rich panels:
  1. Pick which recent command you want reviewed (shell history list)
  2. Preview the captured block (cpblock output)
  3. Edit the prompt (default: "diagnose + fix")
  4. Choose an action: print reply / copy / spawn interactive agent / cancel

Advisory-only: agent is invoked with its one-shot flag so replies are text,
no auto-edits. To iterate further with the context pre-loaded, pick the
"Spawn interactive agent" action.

Depends on:
  - dot_config/zsh/tools/02_shell_integration.zsh (OSC 133 markers)
  - dot_config/zsh/tools/03_tmux_capture.zsh (cpblock)
  - zsh on PATH (calls `zsh -ic …` for history + cpblock)
  - tmux (we run inside a pane)
  - at least one of: claude / opencode / codex / cursor-agent
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass

import questionary
from rich.console import Console
from rich.panel import Panel

DEFAULT_FIX_PROMPT = (
    "Here is a command I ran in my terminal and its output. "
    "Diagnose any errors and suggest a concrete fix. Be brief and specific."
)

AGENT_FLAG_MAP = {
    "claude": ("-p",),
    "opencode": ("run",),
    "codex": ("exec",),
    "cursor-agent": ("-p",),
}

console = Console(stderr=False)


@dataclass
class HistoryEntry:
    n: int          # 1-based index: 1 = most recent
    command: str    # the command text


def detect_agents() -> list[str]:
    """Return the subset of known agents found on PATH, in preference order."""
    return [a for a in AGENT_FLAG_MAP if shutil.which(a)]


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
    """Fetch the last `n` shell commands via `fc -ln -{n}`.

    Returns a list ordered most-recent-first, with `.n` matching what
    cpblock/cpcmd/cpout expect as their positional N arg.
    """
    out = zsh_run(f"fc -ln -{n}")
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    # fc output is oldest-first; reverse so index 1 == most recent
    return [HistoryEntry(n=i, command=cmd) for i, cmd in enumerate(reversed(lines), start=1)]


def capture_block(n: int) -> str:
    """Return cpblock N's stdout."""
    return zsh_run(f"cpblock {n}", timeout=10.0)


def invoke_agent_oneshot(agent: str, prompt: str) -> str:
    """Invoke an agent in non-interactive mode, return its stdout."""
    flags = AGENT_FLAG_MAP[agent]
    result = subprocess.run(
        [agent, *flags, prompt],
        capture_output=True,
        text=True,
        timeout=180.0,
    )
    if result.returncode != 0:
        console.print(f"[red]{agent} exited {result.returncode}[/red]")
        if result.stderr:
            console.print(f"[dim]{result.stderr}[/dim]")
    return result.stdout


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

    # 1. Pick a command
    choices = [
        questionary.Choice(
            title=f"{h.n:>2}  {h.command[:100]}",
            value=h.n,
        )
        for h in history
    ]
    picked_n = questionary.select(
        "Pick a command to review:",
        choices=choices,
        qmark="▸",
    ).ask()
    if picked_n is None:
        return 1

    # 2. Capture + preview the block
    block = capture_block(picked_n)
    if not block.strip():
        console.print(
            f"[red]cpblock {picked_n} returned empty.[/red]\n"
            "[dim]Possible causes: shell pre-dates chezmoi apply (try `exec zsh`); "
            "N exceeds this pane's command history.[/dim]"
        )
        return 1
    console.print(Panel(block.rstrip(), title=f"Block -{picked_n}", expand=False))

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
    with console.status(f"[cyan]Asking {agent}…[/cyan]", spinner="dots"):
        reply = invoke_agent_oneshot(agent, full_prompt)

    if not reply.strip():
        console.print("[yellow]Agent returned empty reply.[/yellow]")
        return 1

    if action == "print":
        console.print(Panel(reply.rstrip(), title=f"{agent} reply", expand=False))
    elif action == "copy":
        ok = copy_to_clipboard(reply)
        if ok:
            console.print(f"[green]Copied {len(reply)} bytes to clipboard.[/green]")
        else:
            console.print("[red]No clipboard tool available.[/red]")
            return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
