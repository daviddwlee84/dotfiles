# `specstory run` grows to multi-gigabyte RSS, one resident process per agent pane

**Symptoms** (grep this section): Activity Monitor shows several `specstory` /
`specstory_darwin_arm64` entries with memory footprints like `8.09 GB`, `6.64 GB`,
`821.6 MB`; `ps -axo pid,ppid,rss,%cpu,etime,command | rg '[s]pecstory'` shows
`specstory run claude ...` at `1257120` KB RSS (≈1.20 GB) and `%CPU` in the 75–115
range; machine starts swapping with three or four agent panes open; there is **no**
separate `specstory watch` or `specstory sync` process to kill; killing the
`specstory run` process orphans the agent and the shell takes the terminal
foreground back, so the still-live Claude/Codex TUI starts misbehaving or gets
`SIGTTIN`-suspended.

**First seen**: 2026-09
**Affects**: specstory CLI 2.x (observed on 2.9.x), macOS + Linux, any workflow that
opens one `specstory run <agent>` per pane — `hvibe`, `hcode`, `sesh`, the yazi
launchers, `claude-copilot` / `codex-copilot`
**Status**: no upstream fix — workaround documented, architectural change queued in
[`backlog/specstory-detached-transcript-capture.md`](../backlog/specstory-detached-transcript-capture.md)

## Symptom

Open three or four agent panes the normal way (`hvibe`, `hcode`, or plain
`claude-copilot`), let the sessions run for a few hours with large contexts, then:

```
❯ ps -axo pid,ppid,rss,%cpu,etime,command | rg '[s]pecstory'
28330  1182  533424  75.2   07:46 specstory run codex -c codex -c model_reasoning_effort="high" ...
23911 23812 1257120  75.8   10:27 specstory run claude -c claude --dangerously-skip-permissions ...
21172 21075  505152 113.8   11:42 specstory run claude -c claude --dangerously-skip-permissions ...
```

Activity Monitor's *Memory* column reported `8.09 GB` / `6.64 GB` / `821.6 MB` for
the same three processes a few minutes earlier. The two metrics disagree because
macOS "memory footprint" and `ps` RSS count different things (compressed pages, Go
GC arenas), but both are far above what a Markdown writer should need, and the peak
is what pushes the machine into swap.

Note what is **not** in that listing: no `specstory watch`, no `specstory sync`. The
memory belongs to the process that is also the agent's parent.

## Root cause

`specstory run` is **not** a sidecar you can stop independently. It is the agent's
wrapper and parent process:

```text
shell / herdr pane
        │
        ▼
specstory run claude          ← the process holding the memory
        ├── watcher goroutine
        ├── autosave / markdown rendering
        └── exec.Command("claude", ...)   ← inherits this terminal's stdin/stdout/stderr
              │
              ▼
          Claude Code
```

It starts the watcher, launches the agent as a child sharing the terminal, and
blocks until the agent exits before stopping the watcher. So:

1. **The cost is per pane.** Every agent pane starts a whole second parser/renderer
   runtime alongside the agent. Four panes, four of them. `_sesh_wrap_agent`
   (`dot_config/shell/22_sesh.sh:90`) is the single place that emits `specstory run`,
   and `24_herdr.sh` calls it once per pane.
2. **It grows with the transcript, not with the delta.** A long agent session is
   re-materialised into intermediate objects on change; a few hundred MB of JSONL
   becomes multiple GB of live heap.
3. **You cannot detach the watcher at runtime.** There is no `run --no-autosave` and
   no runtime-detach flag; the watcher is a goroutine inside this process, not a
   child you can signal.

## Workaround

**Do not `pkill -f 'specstory.*watch'` or kill the `specstory run` PID of a session
you care about.** Unix does not kill the child when the parent dies, so the agent
usually survives — as an orphan whose shell has already taken back terminal
foreground ownership. The TUI then reads from a terminal it no longer owns and gets
`SIGTTIN`-suspended, or simply renders wrongly.

Options that actually work today:

```sh
# 1. Let long sessions end normally, then start fresh panes. The memory is
#    released with the process; nothing reclaims it in-place.

# 2. Opt out of transcript capture for a session you know will be huge.
#    Supported by every wrapper; the agent then runs with no parent.
claude-copilot --no-specstory
codex-copilot  --no-specstory
hvibe --no-specstory
hcode --no-specstory

# 3. Keep sessions scoped. /clear between unrelated tasks bounds what has to be
#    re-materialised, which helps both the model context and this.
```

`--no-specstory` costs you the `.specstory/history/*.md` transcript for that
session — the agent's own native history (`~/.claude`, `~/.codex`) is unaffected.

## Prevention

- Treat "one agent pane = one extra multi-hundred-MB process" as the baseline cost
  when deciding how many panes to open. Two or three long-running panes is very
  different from six.
- Prefer `--no-specstory` for the deliberately-long session (a multi-hour refactor,
  a big migration) and keep capture on for the short ones you actually want a
  transcript of.
- Check before blaming something else: `ps -axo pid,ppid,rss,command | rg '[s]pecstory'`
  attributes the memory in one line.
- The real fix is to stop wrapping the agent at all and sync afterwards — see the
  backlog note. Do not attempt it piecemeal: `specstory sync` is currently used
  **nowhere** in this repo, and the session-id plumbing it needs does not exist yet.

## Related

- [`backlog/specstory-detached-transcript-capture.md`](../backlog/specstory-detached-transcript-capture.md) — the queued `specstory sync -s` architecture
- [`specstory-run-default-agent-drift.md`](specstory-run-default-agent-drift.md) — the other reason never to treat `specstory run` as an interchangeable prefix
- [`specstory-custom-command-drops-configured-flags.md`](specstory-custom-command-drops-configured-flags.md) — why the `-c` base command comes from specstory's own config
- [`redact-secrets-loop-with-active-specstory-writer.md`](redact-secrets-loop-with-active-specstory-writer.md) — the sibling "specstory is a long-lived writer" trap
- [`docs/tools/specstory-internals.md`](../docs/tools/specstory-internals.md) — how the wrapper and the history layout fit together
- [`macos-swap-files-never-shrink.md`](macos-swap-files-never-shrink.md) — why the machine stays slow after the peak is over
