# rclone Television channels — remotes browser + subcommand reference

## Context

`rclone` is installed by `dot_ansible/roles/devtools/tasks/main.yml` (Homebrew on macOS, `downloads.rclone.org` standalone on Linux) and listed in `dot_config/docs/tools/cli-tools.md`, but it has no dedicated tv channel yet. Users who run `tv tools` and pick `rclone` get only the 8-example tldr page that the question quoted.

The ask is a tv-native surface for rclone that:

- **Previews remotes** — quota / about + top-level dirs at a glance, with deeper drill-ins on demand.
- **Surfaces about/summary info** — `rclone about --json`, `rclone size --json`, `rclone config show` so users don't have to remember which subcommand answers which question.
- **Quick-references subcommands** — discover the ~45 commands in `rclone help` and read their `--help` without leaving tv.

Per the clarifying questions: **two separate channels** (one per concern), preview defaults to top-level only with **Ctrl+F cycling** to deeper views including `rclone config show`, and **Enter on a remote drills in** by re-launching tv scoped to that remote (mlflow's drill pattern).

## Files to create

| Path | Purpose |
|---|---|
| `dot_config/television/cable/rclone.toml` | Remotes browser — drill-in picker, about/size/config previews, multi-action Alt-key bindings |
| `dot_config/television/cable/rclone-help.toml` | Subcommand reference — parses `rclone help`, previews `rclone <sub> --help` |

No helper scripts. Both channels stay self-contained in TOML — `rclone` ships rich JSON output (`--json`) and structured help, so the preview commands are short one-liners that pipe to `jq -C` / `bat`. This matches the `fleet-hosts.toml` style (shell-out to the CLI) rather than the `mlflow.toml` style (Python helpers in `~/.config/television/`).

## `rclone.toml` design

**Source** (initial): `rclone listremotes` → one `remote:` per line.

**Source rewriting on drill** (Enter action): `tv rclone --source-command "..."` with a command that calls `rclone lsf -d PATH` and prefixes each row with the parent path so subsequent drills keep working. The `--input-header` is updated to show the current path crumb.

**Display / output**: rows are just the full path (`remote:` or `remote:dir1/dir2/`). Single-column TSV-free format keeps drill-in easy.

**Preview cycling (Ctrl+F)** — four views in order, with path-aware branching so a drilled subdir doesn't try to call `rclone about` (which is per-remote, not per-path):

1. **Default — about + top-level dirs**. If path is a remote root (`remote:`), runs `rclone about --json | jq -C .` then `rclone lsd remote: --max-depth 1`. If path is a subdir, runs `rclone lsd PATH --max-depth 1` then `rclone size PATH --json | jq -C .`.
2. **Deeper listing** — `rclone lsd PATH --max-depth 2` (slower; opt-in via Ctrl+F).
3. **File-level listing** — `rclone lsf PATH | head -200` (shows both files and dirs flat; useful for "what's actually in here").
4. **Config view** — `rclone config show REMOTE` (extracted from path with `awk -F: '{print $1}'`). Header notes that obscured tokens are reversible base64, not encryption.

**Keybindings** — follows the `fleet-hosts.toml` + `mac-apps.toml.tmpl` Alt-key convention (Alt+ avoids tmux/TV conflicts; CLAUDE.md "Keybinding" cross-file rule):

| Key | Action | Notes |
|---|---|---|
| Enter | drill-in | re-launch tv scoped to selected path |
| Ctrl+Y | copy path | uses the same `_clip()` abstraction (pbcopy / wl-copy / xclip / OSC 52) lifted from `mlflow.toml` |
| Alt+A | about (paged) | `rclone about PATH --json | jq -C . | less -R` |
| Alt+S | size (paged) | `rclone size PATH --json | jq -C . | less -R` — counts objects + total bytes |
| Alt+B | browse with ncdu | `rclone ncdu PATH` — opt-in full-screen TUI for users who explicitly want it |
| Alt+C | config show (paged) | `rclone config show REMOTE | less -R` — the explicit opt-in for config viewing |
| Alt+M | mount status | `mount | grep rclone || echo '[no active rclone mounts]'` |

## `rclone-help.toml` design

**Source**: parse `rclone help` for the `Available commands:` block. One-liner:

```sh
rclone help 2>/dev/null | awk '/^Available [Cc]ommands:/{f=1; next} /^Flags:/{f=0} f && /^[[:space:]]+[a-z]/ {sub(/^[[:space:]]+/,""); print}'
```

Each row becomes `<subcmd>  <description>`. Display extracts column 0 with `{split: :0}` (matches `tools.toml` placeholder style).

**Preview cycling (Ctrl+F)**:

1. `rclone <sub> --help | bat --color=always --plain --paging=never --language=help` — primary view.
2. `tldr rclone-<sub> 2>/dev/null || echo '[no tldr page]'` — fallback to upstream tldr if it exists (most don't, but `rclone-copy`, `rclone-sync`, `rclone-mount` do).

**Keybindings**:

| Key | Action |
|---|---|
| Enter | full `--help` in `less -R` so the user can scroll |
| Ctrl+Y | copy `rclone <sub> ` (trailing space, mirrors the `cli-tools.md` "needs argument" convention) |

## Critical files referenced

- `dot_config/television/cable/mlflow.toml` — copy the `_clip()` action body and the `--source-command` drill-in pattern verbatim
- `dot_config/television/cable/fleet-hosts.toml` — shell-out-to-CLI style for the simpler subcommand channel
- `dot_config/television/cable/mac-apps.toml.tmpl` — Alt-key namespacing convention + `reload_source` chaining
- `dot_config/television/cable/tools.toml` — awk parsing pattern for the subcommand source

## Cross-file maintenance (per CLAUDE.md table)

- **No `mkdocs.yml` change** — no new doc page is being added.
- **No `cli-tools.md` change** — rclone is already listed.
- **No alias-table change** — these are tv channels, not shell aliases.
- **No completions to add** — rclone's own `complete` machinery is already handled by `generate_completions.sh` (it ships `rclone completion zsh` / `rclone completion bash`); auditing this is **not** in scope for this plan but worth a follow-up if missing.

## Verification

1. **Render the channels** — `chezmoi diff dot_config/television/cable/rclone.toml dot_config/television/cable/rclone-help.toml`, then `chezmoi apply` (no run-scripts triggered since only static files change).
2. **Confirm tv discovers them** — `tv channels` should list `rclone` and `rclone-help` with the metadata descriptions.
3. **Functional smoke (remotes)**:
   - `tv rclone` → picker opens; if no remotes are configured, the source returns empty (acceptable; matches `fleet-hosts` behavior on a fresh host).
   - Configure a throwaway local remote: `rclone config create _tvtest local type=local` → `tv rclone` lists `_tvtest:`.
   - Cycle preview (Ctrl+F) through all 4 views; confirm Ctrl+F #4 shows `rclone config show _tvtest`.
   - Enter → drills in; input-header updates to `rclone / _tvtest:`; preview switches to subdir mode (no `about`).
   - Alt+A / Alt+S / Alt+C exit to pager and return to picker cleanly.
   - Cleanup: `rclone config delete _tvtest`.
4. **Functional smoke (help)**:
   - `tv rclone-help` lists ~45 subcommands.
   - Pick `mount`; default preview shows `rclone mount --help`; Ctrl+F cycles to `tldr rclone-mount`.
   - Enter pages `rclone mount --help` in `less -R`.
   - Ctrl+Y copies `rclone mount ` (with trailing space) to clipboard.
5. **Cross-platform** — both channels are plain `.toml` (no `.tmpl`), so they deploy identically on macOS and Linux. Smoke-test the Alt+M mount-status action on Linux too (`mount` grep syntax is portable).
