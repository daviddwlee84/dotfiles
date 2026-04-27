# Plan: `mrun` — fire-and-forget into a detached tmux/zellij session

## Context

Today the user has no shell-level "nohup-but-into-a-multiplexer" helper. The
existing flow is manual: open tmux → type the command → detach. The closest
in-repo helpers (`sesh-here`, `sesh-root`, `sesh-code`, `sesh-vibe` in
`dot_config/zsh/tools/22_sesh.zsh`) all *attach you*, which is the wrong
shape for "kick off a long-running command and walk away, come back if I
care."

Goal: a single low-ceremony helper that **creates a fresh detached
multiplexer session at `$PWD`, runs CMD inside it, returns immediately, and
prints an attach hint**. Backends: **tmux** (default) and **zellij**, both
already installed by this repo (zellij via
`dot_ansible/roles/devtools/tasks/main.yml:2169–2279`).

User-confirmed design choices:

- Fail loud on session-name collision; opt-in `-f/--force` to kill+recreate.
- Zellij backend uses an ephemeral KDL layout file + detached spawn (atomic,
  supports cwd; the two-step `attach --create-background` + `zellij run`
  alternative was rejected).
- Soft-warn on stderr when CMD looks like an interactive TUI; still create
  the session (parked-editor workflow stays valid).

## Files to edit

| Path | Edit | Notes |
|---|---|---|
| `dot_config/zsh/tools/23_mrun.zsh` | **NEW FILE** (~170 lines) | Defines `mrun` dispatcher + `tmrun` / `zjrun` wrappers + private `_mrun_*` helpers. |
| `docs/zsh/aliases.md` | **APPEND 3 ROWS** in "Session Management" table (around line 451) | One row each for `mrun`, `tmrun`, `zjrun`. CLAUDE.md-mandated. |

No other files change. **Do not** touch `22_sesh.zsh`, `CLAUDE.md`,
`docs/tools/sesh.md`, or any zellij layout under `dot_config/zellij/`.

## Reusable helpers (read-only references)

- `_sesh_sanitize` (`dot_config/zsh/tools/22_sesh.zsh:54`) — strips `.`,
  `:`, whitespace → `-`. Source-order in `dot_config/zsh/tools/` puts
  22_sesh before 23_mrun, so direct call works.
- `_sudo_spawn_watchdog` (`scripts/lib/sudo_shared.sh`) — precedent for
  the **setsid → nohup macOS fallback** the zellij backend needs. See
  `pitfalls/sudo-shared-setsid-macos.md` for why bare `setsid(1)` is not
  safe (macOS has no `setsid(1)` CLI in base; bare invocation silently
  fails to `/dev/null`).
- KDL `pane cwd="…" { command "…" args "…" }` syntax —
  `dot_config/zellij/layouts/claude-sidecar.kdl` is the in-repo reference.

## `23_mrun.zsh` — function design

### Public API

```
mrun [-b tmux|zellij] [-n NAME] [-d DIR] [-f|--force] [--no-detach] [--] CMD [ARGS...]
tmrun ...   # mrun -b tmux
zjrun ...   # mrun -b zellij
```

- `-b BACKEND` — `tmux` (default) or `zellij`. Env override `MRUN_BACKEND`.
- `-n NAME` — explicit session name. Default: `run-<sanitized-basename>-<rand4>`.
- `-d DIR` — working dir for the inner command. Default `$PWD`.
- `-f` / `--force` — kill an existing session of the same name first.
- `--no-detach` — attach immediately after creating (debug aid).
- `--` — explicit end-of-flags.

No CMD → exit 2, hint to use `shere` for an interactive shell session.

### Private helpers

- `_mrun_default_name()` — `printf 'run-%s-%04x' "$(_sesh_sanitize "$(basename "$PWD")")" $((RANDOM % 65536))`.
- `_mrun_spawn_detached "$@"` — mirrors `_sudo_spawn_watchdog`: `setsid` if
  available, else `nohup … & disown`.
- `_mrun_kdl_escape "$str"` — escape `\` then `"` for embedding in a
  double-quoted KDL string (order matters).
- `_mrun_warn_if_tui "$1"` — match `argv[0]` against
  `vim|nvim|emacs|less|more|man|htop|top|btop|lazygit|lazydocker|tig|k9s|ranger|yazi`
  → one-line stderr note "mrun: '<cmd>' is interactive — you'll need to
  attach to use it".

### Backends

**tmux** — clean one-liner; tmux supports `argv` after `-n WIN`:

```zsh
tmux new-session -d -s "$session" -c "$workdir" -n run sh -c "$cmd"
```

`$cmd` is built via `printf '%s ' "$@"` — single shell line so users can
pipe / `&&` / set env-vars. Pre-check `tmux has-session -t "=$session"` for
collision; with `-f`, run `tmux kill-session -t "=$session"` first.

**zellij** — generate ephemeral layout, spawn detached:

1. `layout=$(mktemp "${TMPDIR:-/tmp}/mrun-layout-XXXXXX")` — note macOS-safe
   template form (full path, no `-t prefix`).
2. Heredoc the layout, with cwd and command both KDL-escaped:
   ```
   layout {
       tab name="run" {
           pane cwd="$esc_dir" {
               command "sh"
               args "-c" "$esc_cmd"
           }
       }
   }
   ```
3. Pre-check via `zellij list-sessions --no-formatting --short | grep -qx`;
   with `-f`, run `zellij delete-session --force "$session"` first.
4. Spawn: `_mrun_spawn_detached zellij --layout "$layout" attach --create "$session"`.
5. **Do not delete `$layout`** — zellij re-reads it on session resurrection.
   `/tmp` GC handles the ~200B leak per invocation.

### Attach hint (always to stderr, single line)

- tmux outside any `$TMUX`: `mrun[tmux]: started '<name>'. Attach: tmux attach -t <name>`
- tmux inside `$TMUX`: `... Attach: tmux switch-client -t <name>` (mirrors `_sesh_attach_or_switch`)
- zellij: `mrun[zellij]: started '<name>'. Attach: zellij attach <name>`
- zellij when `$ZELLIJ` is set: extra line — "you're inside zellij '$ZELLIJ';
  detach (Ctrl+o d) before attaching".

### Nesting

Both backends create a parallel detached session regardless of `$TMUX` /
`$ZELLIJ` (option (b) from the design discussion). Only the *attach hint*
adapts (switch-client vs attach for tmux; warning prefix for zellij).
Cross-multiplexer (e.g. `tmrun` from inside zellij) is unguarded — they
coexist fine.

### File-load guard

```zsh
if ! command -v tmux >/dev/null 2>&1 && ! command -v zellij >/dev/null 2>&1; then
    return 0
fi
```

Per-backend availability checked at dispatch time, not load time, so
installing one backend later doesn't require a `chezmoi apply`.

## `docs/zsh/aliases.md` — rows to add (Session Management section)

```
| `mrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | Fire-and-forget: detached tmux/zellij session running CMD at `$PWD`, returns immediately. `mrun [-b tmux\|zellij] [-n NAME] [-d DIR] [-f] [--] CMD [ARGS...]`. Backend default tmux (override via `$MRUN_BACKEND`). Prints attach hint to stderr |
| `tmrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | `mrun -b tmux`. Attach with `tmux attach -t NAME` |
| `zjrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | `mrun -b zellij`. Generates ephemeral KDL under `$TMPDIR/mrun-layout-*`, spawns detached zellij session. Attach with `zellij attach NAME` |
```

## Verification

Manual end-to-end (no automated tests; the helpers are stateful by design):

```sh
# Reload zsh tools so 23_mrun.zsh is sourced
exec zsh

# 1) tmux backend, default name
tmrun -- sh -c 'while sleep 1; do date; done'
tmux ls | grep run-                         # session present
tmux attach -t run-…                        # see dates ticking; Ctrl-b d
tmux kill-session -t run-…

# 2) tmux backend with name + dir + pipeline (validates sh -c wrap)
tmrun -n probe -d /tmp -- 'ls -la | wc -l > /tmp/probe.out'
sleep 2 && cat /tmp/probe.out               # > 0

# 3) collision — fail loud, then -f succeeds
tmrun -n probe -- sleep 60                  # exits 1 with hint
tmrun -f -n probe -- echo 'recreated'       # succeeds

# 4) TUI soft-warn
tmrun -- nvim                               # one stderr line; session still made
tmux kill-session -t run-…

# 5) zellij backend
zjrun -- sh -c 'for i in 1 2 3 4 5; do echo $i; sleep 1; done'
zellij list-sessions                        # session present
ls -la "${TMPDIR:-/tmp}/mrun-layout-"*      # layout file persisted
zellij attach run-…                         # Ctrl-o d to detach

# 6) zellij quoting torture
zjrun -- 'echo "hi \"there\"" && echo $HOME'
zellij attach run-…                         # output: hi "there", then $HOME

# 7) nesting hint adapts
tmux new -s host
# inside the session:
tmrun -- echo hi                            # hint says: tmux switch-client -t …

# 8) error paths
mrun                                        # exit 2, usage hint
mrun -b foo -- echo hi                      # exit 2, unknown backend
MRUN_BACKEND=zellij mrun -- echo hi         # env override applied
```

If both backends pass step 5 + step 6, the layout-escape and detach-spawn
work. If step 3 + step 7 pass, the collision and nesting branches are
correct. Step 4 confirms the soft-warn doesn't gate creation.

## Out of scope (explicit non-goals for this PR)

- No `_sesh_on_exit_wrap`-style "shell on exit" / "respawn on exit" mode.
  `mrun` is fire-and-forget; if the inner command exits, the session
  vanishes. Documented in `mrun --help`.
- No log-tee to a file. If the user wants persistent logs, use `pueue` —
  documented in `36_pueue.zsh`. The doc row should not promise this.
- No keybinding (no `Alt+M`-style picker entry). `mrun` is invoked from the
  prompt; pickers are for `sesh-*`.
- No completions for tmux/zellij session names. Out of scope for v1.
- No CLAUDE.md edits — the "Custom aliases & shell functions" rule already
  governs this surface and points at `docs/zsh/aliases.md`.
