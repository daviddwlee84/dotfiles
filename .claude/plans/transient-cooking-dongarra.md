# herdr: `prefix + E` — run an arbitrary command in a floating popup

## Context

`prefix + G` (lazygit) proves the shape the user wants — a transient pane that runs
something and disappears when it exits — but its command is hardcoded. The workarounds all
have friction: `prefix + c` + Enter + type + `exit` is four steps and disturbs the tab bar,
and `prefix + `` ` `` (scratch shell) leaves you in a shell you have to exit manually.

The ask: **one key → type/pick any command → it runs in the focused pane's cwd → the popup
closes on its own and you're back where you were.**

herdr 0.7.4 added exactly the missing primitive: `type = "popup"` (session-modal floating
terminal, `width`/`height` in cells or percentages, **no change to the tiled tab layout**) —
the real `tmux display-popup -E` analog. We are on 0.7.5, so it is available.

### Why not `prefix + y` (herdr-plus Quick Actions), as asked

Two hard blockers, both already known to this repo:

1. **No PTY / no stdin.** herdr-plus runs an action through `sh -c` with no terminal. This is
   why btop and nvtop are `[[keys.command]]` panes and *not* Quick Actions — the rationale is
   already written down in `.chezmoitemplates/herdr/config.toml` above the `prefix+M` /
   `prefix+N` bindings. An interactive prompt cannot work there.
2. **No free-text input.** Every Quick Action is a fixed `command = "…"` string
   (`dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions/*.toml`). The
   mechanism has no query field.

So this belongs in `[[keys.command]]`, not Quick Actions.

## Decisions taken (confirmed with the user)

| | Choice |
|---|---|
| Entry | fzf over shell history + free text (matches `url-pick.sh` / `path-pick.sh`) |
| On exit | close on success; on failure show `exit N` and wait for a key |
| Shell | `$SHELL -ic` by default so the repo's large alias/function set resolves; `--sh` escape hatch |
| Key | `prefix + E` ("Execute") |

## Verified during planning

- `herdr config check` accepts `key = "prefix+E"` + `type = "popup"` + `width`/`height` → `config: ok`.
- `prefix+shift+e` is **free**: no herdr builtin uses it (builtin shift keys are `d g n p r t w x`).
- `config check` catches real mistakes — it flags custom-vs-custom collisions
  (`prefix+shift+g: kept keys.command[0].key, disabled keys.command[19].key`) and unknown keys.
  It does **not** flag a custom command shadowing a *builtin* default; the repo already relies
  on that (`prefix+N` shadows `new_workspace`, `prefix+P` shadows `rename_pane`, `prefix+D`
  shadows `close_workspace`). `prefix+E` shadows nothing.
- **fzf exit codes cleanly separate the three outcomes** (tested):
  | Outcome | exit | `--print-query` output |
  |---|---|---|
  | picked a history entry | 0 | line 1 = query, line 2 = selection |
  | typed a brand-new command | 1 | line 1 = query only |
  | pressed Esc | 130 | abort, run nothing |
- **Two portability bugs found and fixed in the history pipeline:**
  - `~/.zsh_history` is extended-history format (`: <ts>:<elapsed>;<cmd>`) and contains
    non-UTF8 bytes. Plain `sed` on macOS dies with `sed: RE error: illegal byte sequence`
    (confirmed: fails at default locale, clean under `LC_ALL=C`). **All history parsing must
    run under `LC_ALL=C`.**
  - `tail -r` is BSD-only and `tac` is GNU-only. Use POSIX awk to reverse instead.
  - Working pipeline (1380 deduped entries on this host, newest first):
    ```sh
    LC_ALL=C sed 's/^: [0-9]*:[0-9]*;//' "$hist" | grep -v '\\$' | awk 'NF' \
      | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) if(!seen[a[i]]++) print a[i]}'
    ```
- `$HISTFILE` is **not** exported to a `sh -c` context, so the script must default it to
  `~/.zsh_history`.
- atuin is configured in this repo (`dot_config/shell/15_atuin.sh`) but is **not installed on
  this host** — its role expects `/opt/homebrew/bin` and this is an Intel Mac (`/usr/local`).
  So atuin is treated as an optional upgrade, never a dependency.

## Implementation

### 1. New helper — `dot_config/herdr/executable_run-command.sh`

Model it directly on `dot_config/herdr/executable_url-pick.sh`, which establishes every
convention to follow: `#!/usr/bin/env sh`, `set -eu`, POSIX only, a header comment naming the
source path / consumers / doc section, `command -v … || { echo "run-command: …" >&2; exit 1; }`
guards, and absolute-path fallbacks for repo binaries (a command pane runs via `sh -c` without
the interactive PATH).

```
run-command.sh [--cwd DIR] [--sh] [QUERY...]
```

- **cwd** — reuse the established resolution chain from `path-pick.sh`:
  `--cwd` → `$HERDR_ACTIVE_PANE_CWD` → `herdr pane get` `foreground_cwd` → `$PWD`.
  Preferring the env var matters: it is injected by herdr itself, so the helper still works
  while the CLI is protocol-mismatched.
- **pick** — fzf with `--print-query --no-sort --height=100% --border`, prompt showing the
  cwd basename, seeded from any `QUERY` args. Branch on the three exit codes above.
  Fallback to `printf` + `read -r` when fzf is absent.
- **run** — `cd` to the resolved cwd, then `"$SHELL" -ic "$cmd"`; `--sh` switches to `sh -c`.
- **exit** — capture `rc`; `rc = 0` → exit silently (popup closes). `rc != 0` → print
  `exit $rc` and wait for a key. `HERDR_RUN_HOLD=always|never|fail` overrides (default `fail`).
  Note the sibling precedent for "make a message visible before the pane closes" is
  `sleep 1.5` in `url-pick.sh:91`; a keypress wait is the deliberate upgrade here.

### 2. Bind it — `.chezmoitemplates/herdr/config.toml`

Add beside the existing command-pane block, with a comment explaining `popup` vs `pane`
(popup does not disturb the tiled layout) and that it needs herdr ≥ 0.7.4:

```toml
[[keys.command]]
key = "prefix+E"
type = "popup"
command = "~/.config/herdr/run-command.sh"
width = "80%"
height = "70%"
description = "run a command in the pane cwd (popup)"
```

### 3. Docs — `docs/tools/herdr.md` **and** `docs/tools/herdr.zh-TW.md`

- One row in the keybindings table (`prefix + E`, type `popup`).
- A short section: the popup-vs-pane-vs-tab distinction, the hold-on-failure rule and its
  `HERDR_RUN_HOLD` override, the `--sh` flag, and the Quick-Actions-can't-do-this rationale.
- Note the `type = "popup"` requirement (herdr ≥ 0.7.4) next to the existing 0.7.4 note.

No `docs/shells/aliases.md` row is needed — this ships no shell alias. (A `hrun` wrapper
mirroring `hmark` is a natural follow-up but is deliberately out of scope here.)
No `docs/shells/keybindings.md` change either: `prefix + E` is herdr-internal, not a
terminal-level `Ctrl`/`Alt` chord, so there is no tmux root-table shadowing to check.

## Verification

Everything below runs **without** a working herdr server, which matters because the running
server is still 0.7.2 and the CLI is protocol-mismatched:

1. `shellcheck -S error` + `sh -n` on the new helper (matches the repo's pre-commit hooks).
2. Render + validate the config with herdr's own parser:
   ```sh
   chezmoi execute-template < .chezmoitemplates/herdr/config.toml > /tmp/h.toml
   HERDR_CONFIG_PATH=/tmp/h.toml herdr config check    # expect "config: ok"
   ```
3. Drive the helper standalone from a normal terminal — it does not require herdr:
   - `HERDR_ACTIVE_PANE_CWD=/tmp ./run-command.sh` → picker lists history, cwd shows `/tmp`
   - pick an existing entry → runs, popup-equivalent exits 0
   - type a brand-new command (no history match) → runs (covers the fzf exit-1 path)
   - Esc → runs nothing (exit-130 path)
   - `HERDR_ACTIVE_PANE_CWD=/tmp ./run-command.sh -- false` → shows `exit 1`, waits
   - `HERDR_RUN_HOLD=never` → no wait even on failure
   - `--sh` path runs a plain binary; default path resolves an alias (e.g. `gst`)
4. `uv run mkdocs build --strict` — warning count must stay at the 12-line baseline
   (1 nav + 11 llmstxt), no new entries.
5. **In-app, only after the herdr server is restarted** (0.7.5 both sides): `chezmoi apply`,
   then `prefix + E` from a pane in a git repo → popup opens at that repo, run `git status`,
   popup closes; run `false`, popup holds.

## Caveats to record

- Step 5 cannot be done until the user restarts the herdr server (kills pane processes) —
  same blocker as the review-⭐ migration in `9d3a9da`. Everything else is verifiable now.
- `$SHELL -ic` sources the full interactive rc on every invocation (a few hundred ms here).
  That is the accepted cost of alias support; `--sh` is the escape hatch.
- The picker reads zsh history even when the user is in bash. Cross-shell history unification
  is what atuin would give us — worth revisiting if atuin ever lands on this host.
