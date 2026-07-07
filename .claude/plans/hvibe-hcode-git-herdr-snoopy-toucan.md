# Plan: `hhere` / `hroot` — plain "open a herdr space here + attach"

## Context

The herdr helper family in `dot_config/shell/24_herdr.sh` only exposes the two
**heavyweight** entry points: `hvibe` (multi-agent pack) and `hcode`
(nvim|agent + monitor layout). Both **require a git repo** and both build a full
agent layout. There is no lightweight "just open a workspace in this directory
and attach me to it" command.

The tmux side (`dot_config/shell/22_sesh.sh`) already has this pair:
- `shere` / `sesh-here` (`22_sesh.sh:177`) — plain shell session at `$PWD`, no git needed.
- `sroot` / `sesh-root` (`22_sesh.sh:209`) — plain session at git-root (falls back to `$PWD`).

Because with tmux "open a session" lands you directly in the current dir, but
herdr adds a layer (Session → **Workspace** → Tab → Pane), the current workaround
is: launch herdr → create a space in the TUI (opens at `$HOME` per `new_cwd`) →
copy path → `cd`. Bad UX.

**Outcome:** add the missing herdr analogs `hhere` / `herdr-here` and
`hroot` / `herdr-root`, so `hhere` = "create a herdr workspace at `$PWD`, focus
it, and attach if I'm outside herdr" — a one-shot, no git requirement, no agent
layout.

## Approach

Add two small functions + two aliases to **`dot_config/shell/24_herdr.sh`**,
mirroring `sesh-here` / `sesh-root` and reusing the herdr helpers already in the
file. No new helper files, no new dependencies.

### `herdr-here()` (alias `hhere`) — mirror of `sesh-here`

Flags/args identical to `shere`'s "smart argument handling":
- `-p|--path DIR` — target dir (default `$PWD`). **No git requirement** — this is the key difference from hvibe/hcode; do NOT call `_sesh_git_root`.
- `-c|--command CMD` or bare trailing args → run `CMD` in the workspace root pane.
- `--session NAME` — reuse `_herdr_session_target` + the `local -x HERDR_SOCKET_PATH` pattern (same as hvibe/hcode, `24_herdr.sh:304-308`).
- `--no-attach` — build in background.
- `-h|--help` — heredoc, same style as the existing helpers.

Body (reusing existing pieces from `24_herdr.sh`):
1. `target="${target:-$PWD}"`; `label=$(_sesh_sanitize "$(basename "$target")")` (bare basename — matches herdr's own native auto-label convention, unlike the namespaced `vibe/…` / `coding-agent/…` labels).
2. Resolve session via `_herdr_session_target` (lines 65-96 pattern).
3. **Idempotent focus** via `_herdr_ws_by_label "$label"` (lines 31-35) — if a workspace with that label exists, `herdr workspace focus` + `_herdr_attach_if_outside`, return. (Same shape as hvibe/hcode lines 311-320. Note the caveat below.)
4. `herdr workspace create --cwd "$target" --label "$label" --no-focus`; parse `.result.workspace.workspace_id` + `.result.root_pane.pane_id` (same jq as line 324-327).
5. If a command was given: `herdr pane run "$p0" "$cmd"`. (Plain/raw — no specstory or on-exit wrapping; `shere` is deliberately lightweight, agent wrapping stays with hcode/hvibe.)
6. Unless `--no-attach`: `herdr workspace focus "$ws"` + `_herdr_attach_if_outside "$sess_name"` (lines 104-112).

### `herdr-root()` (alias `hroot`) — mirror of `sesh-root`

Same as `herdr-here` except the target resolves to the git-root:
`root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD`. Simplest
implementation: thin wrapper that computes `root` then calls `herdr-here -p "$root" "$@"`
(passing through `-c`/bare-command/`--session`/`--no-attach`). Keeps one code path.

### Aliases

Append next to the existing ones (`24_herdr.sh:527-529`):
```sh
alias hhere='herdr-here'
alias hroot='herdr-root'
```

### Idempotency caveat (document in code comment)

herdr auto-relabels a workspace to the root pane's **live** cwd basename after a
`cd` in tab 1 (see `docs/tools/herdr.md` § cwd & workspace-naming). So the
`_herdr_ws_by_label` reuse is best-effort: if the label has drifted, a re-run
creates a fresh workspace. Acceptable (and arguably correct — you're "somewhere
else" now). Note this in a one-line comment, matching the file's comment density.

## Files to change

| File | Change |
|---|---|
| `dot_config/shell/24_herdr.sh` | Add `herdr-here()` + `herdr-root()` (before the Aliases block) and the two aliases. Reuses `_herdr_ws_by_label`, `_herdr_session_target`, `_herdr_attach_if_outside`, `_sesh_sanitize`. |
| `docs/shells/aliases.md` | Add rows for `hhere`/`herdr-here` and `hroot`/`herdr-root` (name, type, source `24_herdr.sh`, scope, one-line) — required by the CLAUDE.md alias cross-file rule. Place beside the existing `hvibe`/`hcode` rows. |
| `docs/tools/herdr.md` + `docs/tools/herdr.zh-TW.md` | Add `hhere`/`hroot` to the helpers section alongside `hvibe`/`hcode` (the plain-open analogs of `shere`/`sroot`). Keep the zh-TW mirror in sync. |

**Not needed:** no tab-completion files (these are shell functions like
`hvibe`/`hcode`, which have none — the completion rule is for `executable_*`
CLIs); no `mkdocs.yml` nav change (editing existing docs, no new page); no
`SKILL.md.tmpl` edit (it's self-discovering / pointer-based, and these aren't new
prompt keys or executable CLIs).

## Verification

Since herdr is installed on this host (macOS brew):
1. `chezmoi apply` (or source the file) to load the new functions.
2. `type hhere hroot` → confirms both resolve to the functions.
3. From a **non-git** dir: `cd /tmp && hhere` → a herdr workspace opens at `/tmp`, labeled `tmp`, and a client attaches (from outside herdr). Confirms the no-git-required path.
4. `herdr workspace list --json | jq '.result.workspaces[] | {label, ...}'` → the new workspace exists with the expected cwd/label.
5. `hhere -p ~ echo hi` in a fresh dir → workspace at `~`, root pane ran `echo hi`.
6. `cd` into a git repo, run `hroot` from a subdirectory → workspace opens at the repo top-level (not the subdir).
7. Re-run `hhere` in the same dir → focuses the existing workspace instead of stacking a duplicate (idempotency).
8. `hhere -h` / `hroot -h` → help text renders.
9. Syntax sanity for both shells: `bash -n` and `zsh -n` on the rendered file (the file is POSIX-shared, sourced by both).
