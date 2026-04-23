# tmux pane vanishes on Ctrl+C despite `cmd; exec $SHELL` wrapper

**Symptoms** (grep this section):
- A tmux pane built with `tmux new-window -n foo "btop; printf 'hint'; exec \$SHELL"` (or similar `cmd; exec $SHELL` wrapper) closes immediately when you press Ctrl+C inside the running command, even though the wrapper is supposed to drop you into a shell.
- Quitting the same command "cleanly" (e.g. `q` in btop, `:q` in nvim, normal exit) DOES land in shell with the hint as expected — only Ctrl+C kills the pane.
- Inconsistent across tools: agent CLIs (claude, codex, opencode) survive Ctrl+C and land in shell, but `btop`, `htop`, `less`, `man` do not.
- The wrapper string is correct in `tmux list-panes -F '#{pane_start_command}'`; it's not a quoting bug.
- Adding `|| true` between `cmd` and `printf` doesn't help (because `;` already ignores exit codes).

**First seen**: 2026-04
**Affects**: any `tmux new-window CMD "inner; printf …; exec \$SHELL"` pattern where `inner` is a TUI tool that doesn't trap SIGINT itself
**Status**: fixed in `dot_config/zsh/tools/22_sesh.zsh` (`_sesh_on_exit_wrap` now prefixes `trap '' INT;` to the wrapper)

## Symptom

`scode` builds the monitor window with:

```
tmux new-window -n monitor "btop; printf '\n[btop exited — back in shell. Re-run with: btop]\n'; exec $SHELL -l"
```

Behavior matrix observed:

| Inner command | Quit method | Result |
|---|---|---|
| btop | `q` | Lands in shell with yellow hint ✅ |
| btop | **Ctrl+C** | **Window vanishes immediately ❌** |
| htop | `q` / F10 | Lands in shell ✅ |
| htop | **Ctrl+C** | **Window vanishes ❌** |
| nvim | `:q` | Lands in shell ✅ |
| nvim | Ctrl+C (insert mode) | Stays in nvim (nvim handles it) |
| claude / codex / opencode | Ctrl+C → "exit" | Lands in shell ✅ |

The wrapper is the same in all cases. Only the inner command's relationship to SIGINT differs.

## Root cause

**Ctrl+C in a terminal sends SIGINT to the entire foreground process group**, not just the foreground process. The wrapper shell (the one running `inner; printf …; exec $SHELL`) is also in that process group, and its default disposition for SIGINT is to terminate.

Sequence on Ctrl+C:
1. tmux receives Ctrl+C, forwards SIGINT to the foreground PG of the pane.
2. **Both** `btop` AND its parent `sh -c "btop; printf …; exec \$SHELL"` receive SIGINT.
3. btop handles SIGINT by exiting cleanly (rc=130).
4. The wrapper shell **also** got SIGINT — and being a non-interactive script (`sh -c "…"`), its default action is to die immediately. It never advances past `btop;` to execute `printf` or `exec $SHELL`.
5. The pane has no remaining process → tmux closes it (default `remain-on-exit off`).

Why agent CLIs (claude/codex/opencode) survived this: they install their **own** SIGINT handler (to show their own "exit?" prompt), so SIGINT to the PG is consumed by the agent before the agent process exits. The wrapper sh never sees the signal because the agent intercepts and the user has to confirm exit, which then returns to the wrapper via normal exit (no SIGINT in flight). It looked like the wrapper "worked" only because the agents were doing extra work to mask the bug.

Why `cmd1; cmd2` doesn't help — `;` does mean "run cmd2 regardless of cmd1's exit code", BUT only if the shell running them is alive to do so. If the shell itself dies from a signal between cmd1 and cmd2, cmd2 never runs.

`|| true` and `trap … EXIT` likewise don't help — they assume the wrapper shell stays alive long enough to evaluate them. SIGINT to the wrapper kills the wrapper before any of those handlers fire.

## Fix

Make the wrapper shell **ignore** SIGINT. The inner command still receives it (it's in the same PG), so it still exits as the user expects; control then returns cleanly to the wrapper which proceeds to print the hint and exec the login shell.

```diff
 case "$mode" in
     shell|*)
-        print -r -- "$inner; printf '...'; exec \$SHELL -l"
+        print -r -- "trap '' INT; $inner; printf '...'; exec \$SHELL -l"
         ;;
 esac
```

`trap '' INT` (empty action) is "ignore SIGINT". This applies to the wrapper shell only — child processes (the inner command) inherit the *signal mask* but reset *signal handlers* to default on exec, so the inner command still gets SIGINT delivered normally. ([POSIX `exec()` semantics](https://pubs.opengroup.org/onlinepubs/9699919799/functions/V2_chap02.html#tag_15_04): "Signals set to be ignored by the calling process image shall be set to be ignored by the new process image.")

Wait — that POSIX rule says ignored signals stay ignored across exec. So how does the inner command receive Ctrl+C?

It doesn't, technically — but most TUI tools (btop, htop, less) **explicitly install their own SIGINT handler at startup** rather than relying on the inherited disposition. They overwrite the inherited "ignore" with "my custom handler". Tools that DO rely on inherited disposition (rare; some old CLI utilities) would indeed become unkillable by Ctrl+C with this fix — but those tools are extremely rare in TUI / interactive contexts and ~all of them have a `q` quit key.

If you ever hit a tool that needs Ctrl+C delivered AND doesn't install its own handler, the alternative is to wrap with `bash -c '…'` which gives you a fresh process group via `set -m` + `setsid`, so SIGINT only hits the inner. But that costs a process per pane and complicates job-control. `trap '' INT` is the right default.

## Verification

```sh
$ tmux list-panes -t coding-agent/chezmoi:monitor -F '#{pane_start_command}'
"trap '' INT; btop; printf '\n\033[33m[btop exited — back in shell. Re-run with: \033[1m%s\033[0;33m]\033[0m\n' \"btop\"; exec $SHELL -l"

$ # In the pane, run btop, then Ctrl+C.
# Expected: lands in shell with yellow hint.
# Before fix: pane closes.
```

## Red herrings explored

- **`tmux set remain-on-exit on`**: makes the pane stay open as `[exited]` after the wrapper dies, but you lose the shell — you can only close or reset the pane, not work in it. Treats the symptom, not the cause.
- **Quoting `$SHELL` differently** (`'$SHELL'` vs `\$SHELL` vs `${SHELL}`): irrelevant. The wrapper never reaches `exec`.
- **`set -m` (job control)**: requires bash and adds complications; doesn't address the wrapper-also-dies issue.
- **Switching `;` to `&&`**: makes it worse (now printf only runs on rc=0), and still wouldn't help because the shell is dead.
- **Adding `|| true`**: the same misunderstanding — exit codes aren't the problem.

## Related

- `pitfalls/tmux-display-menu-silent-fail.md` — another "tmux pane behaves unexpectedly with no error" case
- `pitfalls/zsh-tied-array-path-shadowing.md` — sister pitfall for the same `dot_config/zsh/tools/22_sesh.zsh` file
- `dot_config/zsh/tools/22_sesh.zsh` → `_sesh_on_exit_wrap` — the function with the fix
