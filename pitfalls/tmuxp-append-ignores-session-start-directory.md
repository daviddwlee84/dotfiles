# sesh-opened repo: nvim / lazygit / shell launch at $HOME despite session_path being correct

**Symptoms** (grep this section):
- `sesh connect <repo>` via a wildcard pattern opens the tmux session, but `nvim` starts with `:pwd` = `/Users/<me>` instead of the repo root
- `lazygit` in the `git` window shows HOME's branch/dirty count, not the repo's
- The `shell` window prompt shows `~` — you have to manually `cd <repo>` after attach
- `tmux display-message -p -t "<session>" '#{session_path}'` returns the **correct** repo path (red herring: session looks fine at the top level)
- `tmux list-panes -s -t "<session>" -F '#{window_name}: #{pane_current_path}'` shows HOME for every window except the one you manually `cd`'d in
- Adding `start_directory: ${start_directory:-.}` at the session level of the tmuxp yaml does nothing
- Changing it to `start_directory: .` lands windows in `~/.config/tmuxp/` (the yaml's directory) instead of the repo
- Adding `start_directory={} tmuxp load -a …` env var prefix in `sesh.toml`'s `startup_command` also does nothing
- `tmux new-window -c /nonexistent` silently creates a pane at `$HOME` with no error (tmux fallback behaviour — the mechanism that turns the broken config into a plausible-looking session)

**First seen**: 2026-04
**Affects**: tmuxp ≥ 1.64.0 (all versions that call `os.path.expandvars`) + sesh wildcard + `tmuxp load --append`
**Status**: workaround documented (yaml omits session-level `start_directory`; sesh.toml prepends `cd {} &&` / `cd ~ &&`)

## Symptom

Session `Personal/agent-skills` was opened via:

```toml
[[wildcard]]
pattern = "/Volumes/Data/Program/*/*"
startup_command = "start_directory={} tmuxp load -a -y ~/.config/tmuxp/project.yaml && …"
```

with `project.yaml`:

```yaml
session_name: project
start_directory: ${start_directory:-.}

windows:
  - window_name: editor
    panes: [{shell_command: nvim}]
  - window_name: shell
    panes: [{shell_command: ""}]
  - window_name: git
    panes: [{shell_command: lazygit}]
```

Post-connect inspection:

```
$ tmux display-message -p -t "Personal/agent-skills" '#{session_path}'
/Volumes/Data/Program/Personal/agent-skills                              ← correct

$ tmux list-panes -s -t "Personal/agent-skills" \
    -F '#{window_name}: #{pane_current_path}'
editor: /Users/daviddwlee84                                              ← WRONG
shell:  /Users/daviddwlee84                                              ← WRONG
git:    /Users/daviddwlee84                                              ← WRONG
```

nvim's `:pwd`, lazygit's active repo, and the interactive shell's starting
cwd are all HOME. The session's own `session_path` is the repo — so the
cause *looks* like a shell-rc bug (zsh `chpwd`, `CDPATH`, some `cd $HOME`
somewhere) but it isn't.

## Root cause

Two bugs compound into one silent failure:

### Bug 1 — Python `expandvars` doesn't understand bash `${VAR:-default}`

tmuxp resolves yaml strings via `tmuxp/workspace/loader.py:expandshell`:

```python
def expandshell(value: str) -> str:
    return os.path.expandvars(os.path.expanduser(value))
```

`os.path.expandvars` handles `$VAR` and `${VAR}` only. The bash-style
fallback form `${VAR:-default}` contains `:-` which is not a valid shell
identifier character, so Python bails out of the `${…}` scan and returns
the expression **literal**:

```python
>>> os.path.expandvars("${start_directory:-.}")
'${start_directory:-.}'            # verbatim — even when $start_directory IS set
```

Net: `start_directory: ${start_directory:-.}` in yaml never expands to
anything. It's dead code in every tmuxp mode (append or direct), and has
been for the lifetime of tmuxp.

### Bug 2 — `tmux new-window -c <invalid-path>` silently falls back to `$HOME`

tmuxp's loader (via `trickle`, loader.py:213-222) does propagate
session-level `start_directory` down to each window. So the literal string
`${start_directory:-.}` is attached to every window, then passed to
libtmux's `session.new_window(start_directory='${start_directory:-.}')`
(session.py:525-527), which hands it to `tmux new-window -c
'${start_directory:-.}'`.

tmux treats `${start_directory:-.}` as an absolute-looking path (no `$HOME`
expansion at the tmux layer either), can't `chdir` to it, and — rather
than erroring — silently uses `$HOME`:

```
$ tmux new-window -c '/nonexistent/path' -n badpath
$ tmux display-message -p -t :badpath '#{pane_current_path}'
/Users/daviddwlee84        ← tmux's silent fallback, no error, no log
```

That fallback is what makes the top-level symptom look like a shell
problem: every window "opened at HOME" because every window's `-c` was
rejected.

### Red herring: "tmuxp append mode ignores session-level start_directory"

Reading `tmuxp/workspace/builder.py:388` (`iter_create_windows`) makes it
*look* like append mode skips session-level `start_directory` — the
function only reads `window_config.get("start_directory")`. But
`loader.py:trickle` runs before the builder and copies the session value
into every window, so session-level does propagate in append mode — it
just propagates a broken string.

## Workaround

### Bug 3 — `.` is resolved against the yaml file's directory, not tmuxp's process cwd

First attempted workaround: replace `${start_directory:-.}` with `.`. That
makes expandvars happy, but tmuxp's `cli/load.py:359` calls
`loader.expand(..., cwd=os.path.dirname(workspace_file))` — relative paths
resolve against the **yaml file's directory**, not the process cwd. So
`start_directory: .` lands every window in `~/.config/tmuxp/` (the
directory containing `project.yaml`) — wrong in a different way.

### The actual fix

Two coordinated edits:

**1. `~/.config/tmuxp/project.yaml` and `~/.config/tmuxp/coding-agent.yaml`**:
**delete** session-level `start_directory`:

```yaml
# Before (broken — see Bugs 1, 2, 3):
session_name: project
start_directory: ${start_directory:-.}
# (or ${start_directory}, or .)

windows:
  - window_name: editor
    ...

# After:
session_name: project

windows:
  - window_name: editor
    ...
```

With no `start_directory` key, tmuxp passes `None` to
`libtmux.Session.new_window`, which omits `-c` from `tmux new-window`.
tmux then inherits the cwd from the caller, and the caller is the pane
running tmuxp (via sesh's `send-keys`).

**2. `~/.config/sesh/sesh.toml`**: prepend `cd <path> &&` so the pane
running tmuxp IS at the target path:

```toml
# Wildcard case:
[[wildcard]]
pattern = "/Volumes/Data/Program/*/*"
startup_command = "cd {} && tmuxp load -a -y ~/.config/tmuxp/project.yaml && …"

# Named session case (coding-agent):
[[session]]
name = "coding-agent"
path = "~"
startup_command = "cd ~ && tmuxp load -a -y ~/.config/tmuxp/coding-agent.yaml && …"
```

Why both: dropping `start_directory` from yaml enables tmux's "inherit
from caller" path; prepending `cd` makes "the caller" actually be at the
target. Either alone is insufficient — remove the `cd` and windows open
wherever the user invoked `sesh connect` from; keep `start_directory:
${VAR:-default}` in the yaml and libtmux hands tmux a literal string it
can't interpret (Bug 2).

Live in the repo at:
- [`dot_config/tmuxp/project.yaml`](../dot_config/tmuxp/project.yaml) — session `start_directory: .`
- [`dot_config/tmuxp/coding-agent.yaml`](../dot_config/tmuxp/coding-agent.yaml) — session `start_directory: .`
- [`dot_config/sesh/sesh.toml`](../dot_config/sesh/sesh.toml) — `cd {} &&` / `cd ~ &&` prefix on both startup_commands

## Red herrings (ruled out during debugging)

- **Shell rc / CDPATH / zsh `chpwd`**: the first instinct, because the
  problem looks like "the shell landed at HOME." But `pane_current_path`
  for `editor` and `git` (which run nvim/lazygit, not a shell) also
  showed HOME — a shell hook couldn't explain that.
- **Sesh not passing `-c`**: ruled out — `#{session_path}` is correct,
  meaning sesh did pass `-c <match>` to `tmux new-session`. Only
  subsequent `tmux new-window` calls were off.
- **"tmuxp `-a` ignores session-level start_directory"**: initial
  hypothesis from reading `builder.py:388` in isolation. Wrong —
  `loader.py:trickle` copies session → window *before* the builder runs.
  The real problem was that the value being propagated was already
  broken.
- **Windows inheriting pane cwd when tmux is invoked from inside a
  pane**: this *is* tmux's behaviour when `-c` is omitted entirely, and
  ends up being the mechanism that makes the real fix work. But while the
  yaml had any `start_directory` value at all, libtmux was always passing
  `-c <something>` (literal `${start_directory:-.}`, or `.` resolved to
  `~/.config/tmuxp/`, or whatever), so the pane-inheritance path was
  masked. Only after **omitting** `start_directory` entirely does libtmux
  skip `-c` and let tmux fall through to the caller-pane cwd.

## Prevention

- Do **not** use bash `${VAR:-default}` / `${VAR:+…}` / `${VAR:=…}` / any
  other bash parameter-expansion form in tmuxp yaml string values.
  Restrict to plain `$VAR` or `${VAR}` (or avoid env vars entirely and
  use `.` + a `cd` prefix in the startup_command).
- When a tmuxp session "opens at HOME" on append, immediately `tmux
  list-panes -s -t <session> -F '#{window_name}:
  #{pane_current_path}'` — if all windows show HOME, suspect invalid `-c`
  (Bug 2) rather than shell rc.
- If someone ever rewrites this to use tmuxinator (Approach C in
  [docs/tools/sesh.md](../docs/tools/sesh.md)), tmuxinator evaluates its
  yaml as ERB (full Ruby) — `root: <%= @settings["root"] || "~" %>` works
  because Ruby actually executes it. That approach side-steps this trap
  entirely but pulls in the Ruby dependency.

## Related

- [`docs/tools/sesh.md`](../docs/tools/sesh.md) → "Per-project layout via tmuxp `--append`" — documents the `cd {}` prefix inline with the config
- [tmuxp `workspace/loader.py:expandshell`](https://github.com/tmux-python/tmuxp/blob/v1.64.0/src/tmuxp/workspace/loader.py#L13) — upstream source of Bug 1
- [tmuxp `workspace/loader.py:trickle`](https://github.com/tmux-python/tmuxp/blob/v1.64.0/src/tmuxp/workspace/loader.py#L191) — proves session→window propagation *does* happen in append mode
- [tmuxp `workspace/builder.py:388`](https://github.com/tmux-python/tmuxp/blob/v1.64.0/src/tmuxp/workspace/builder.py#L388) — the append-mode builder (red-herring source for the original hypothesis)
- [`pitfalls/tmux-pane-vanishes-on-ctrl-c-despite-shell-wrapper.md`](tmux-pane-vanishes-on-ctrl-c-despite-shell-wrapper.md) — another sesh-session pitfall in the same surface area
