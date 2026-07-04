# herdr: fix hvibe/hcode attach + add `--session`, document sessions & `--remote`

## Context

While using herdr the user hit a cluster of small gaps:

1. **`hvibe`/`hcode` don't attach when run from *outside* herdr.** They end with `herdr workspace focus`, which only moves an *already-attached* client's focus. From a plain terminal the workspace is created but nothing appears — you must then type `herdr` to attach. (Inside herdr, `workspace focus` already switches the live client, so that path is fine.)
2. **No way to target a specific herdr session.** A herdr server hosts multiple named **sessions** (`default`, `test`, …), each with its own socket. `hvibe`/`hcode` always hit whatever socket the CLI defaults to. There's no `--session` flag.
3. **Docs gaps.** `docs/tools/herdr.md` is thorough on Workspace→Tab→Pane but never documents (a) that a server hosts **multiple named sessions** (the extra top tree level the user discovered), nor (b) **`herdr --remote`** at all. No `herdr.zh-TW.md` exists.

Empirically verified during planning (we are currently running *inside* herdr's `default` session):
- `herdr` CLI subcommands honor the **`HERDR_SOCKET_PATH`** env var — setting it to another session's `socket_path` routes `workspace create/list` to that session (probe workspace landed in `test`, invisible to `default`). There is **no** `--session`/`--socket` flag on the subcommands; the env var is the only lever.
- Ambient env inside a herdr pane: `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_WORKSPACE_ID`, and `HERDR_SOCKET_PATH` (= current session's socket). So "am I inside herdr" = `[ -n "$HERDR_ENV" ]`, and inside herdr the CLI already targets the current session for free.
- `herdr session list --json` → `.sessions[] | {name, running, socket_path, default}` — authoritative name→socket resolver (the text table's `herdr.socket` is wrong; JSON says `herdr.sock`).
- `herdr --remote <target>` **auto-installs** a matching server binary on the remote over SSH; the user's `Connection closed by … port 22` was transient (key-auth SSH to `local_ubuntu` works now; the client log shows `--remote` bridging clipboard fine the day before).

Outcome: `hvibe`/`hcode` behave correctly from any context and accept `--session`; docs cover named sessions + remote; a zh-TW page and the missing zh-TW alias rows are added.

## Design decisions (resolved)

- **Attach from outside** mirrors `svibe`'s `_sesh_attach_or_switch` ($TMUX branch) but adapted: the repo-named object in herdr is the *workspace*, so we attach the whole **session** and rely on the prior `workspace focus` for landing spot. Attach runs as a **child process (no `exec`)**, exactly like svibe.
- **`--session` targeting** uses `local -x HERDR_SOCKET_PATH=…` (function-scoped export, auto-restored on return — supported in bash 4+ and zsh, matching the file's existing `local -a`/`[[ ]]`/process-subst baseline). Never a bare `export` (would leak the override into the user's shell).
- **`--session` when the target isn't running → error with a hint** (`herdr --session NAME` to start it first), rather than trying to spawn a headless server (chicken/egg with workspace creation). Small, predictable.
- Default session name is `default`; attach via bare `herdr` for default, `herdr session attach <name>` for named.

## Changes

### 1. `dot_config/shell/24_herdr.sh` (primary)

Add two small shared helpers near the existing `_herdr_*` helpers:

```sh
# Resolve the target session for hvibe/hcode from an optional --session value.
# Echoes "<name>\t<socket_override_or_empty>". socket is non-empty ONLY when the
# caller must override HERDR_SOCKET_PATH (explicit --session). Errors (return 1)
# if an explicit --session isn't a running session.
function _herdr_session_target() { … herdr session list --json | jq … ; }

# From OUTSIDE herdr, bring up a client so the just-focused workspace is visible.
# Inside herdr (HERDR_ENV set) the focus calls already switched the live client.
function _herdr_attach_if_outside() {
    [ -n "$HERDR_ENV" ] && return 0
    local session="${1:-default}"
    if [ "$session" = default ]; then herdr; else herdr session attach "$session"; fi
}
```

In **both** `herdr-vibe` and `herdr-code`:
- Parse a new `--session NAME` flag (add to the `while`/`case`, the `-h` help text, and reject empty).
- After arg parsing, resolve the session:
  ```sh
  local sess_line sess_name sess_sock
  sess_line=$(_herdr_session_target "$session_arg") || return 1
  sess_name=${sess_line%%$'\t'*}; sess_sock=${sess_line#*$'\t'}
  [ -n "$sess_sock" ] && local -x HERDR_SOCKET_PATH="$sess_sock"
  ```
  (When inside herdr with no `--session`, `sess_sock` is empty → ambient socket is used untouched; `sess_name` is derived for the — unused — attach path.)
- **Idempotent fast path** (`existing` found): keep `herdr workspace focus "$existing"` but append `_herdr_attach_if_outside "$sess_name"` (still gated on `--no-attach`).
- **End-of-build attach block** (`if [ "$no_attach" -ne 1 ]; then …`): keep the existing `workspace focus`/`tab focus`/`pane focus` lines, add `_herdr_attach_if_outside "$sess_name"` as the last line inside the block.
- Update each `-h` help block: document `--session NAME` and the new "attaches when run outside herdr" behavior.

No change to the reused `_sesh_*` helpers or the layout logic.

### 2. `docs/tools/herdr.md`

- **"Model differences vs tmux"**: state that a herdr **server hosts multiple named sessions** (`default` + named, each its own socket under `sessions/<name>/herdr.sock`); full depth is **Session → Workspace → Tab → Pane** (one level deeper than tmux). Add a short **"Named sessions"** subsection: `herdr --session NAME`, `herdr session list|attach|stop|delete`, and that CLI subcommands target a session via **`HERDR_SOCKET_PATH`** (no `--session` flag on subcommands).
- **New "Remote (`herdr --remote`)"** section: thin-client model (SSHes to target, **auto-installs** the server binary, bridges clipboard/image-paste, keeps local keybindings); usage `herdr --remote <ssh-target> [--session NAME] [--handoff]`; prereqs (SSH access + install perms + a supported host); the `[remote].manage_ssh_config` knob; troubleshooting `remote platform detection failed: Connection closed` = transient SSH close → verify plain SSH reachability + check `herdr-client.log`/`herdr.log`.
- **`hvibe`/`hcode` section**: document new `--session` flag + auto-attach-from-outside.
- Fix the custom-command env note to distinguish **ambient** pane env (`HERDR_ENV`/`HERDR_PANE_ID`/`HERDR_SOCKET_PATH`) from the `[[keys.command]]`-only `HERDR_ACTIVE_PANE_*` vars.

### 3. `docs/tools/herdr.zh-TW.md` (new)

Full zh-TW translation. Reuse the fixed boilerplate: `# Herdr —— …` H1 + the verbatim `!!! note "Terminology rule (zh-TW pages)"` block (copy from `docs/tools/worktrunk.zh-TW.md:1-11`); `中文 (English)` on first use; leave CLI flags/filenames untranslated. Mirror the English section set. No `mkdocs.yml` nav edit needed — the `i18n` plugin (`docs_structure: suffix`) auto-pairs it.

### 4. `docs/shells/aliases.md` + `docs/shells/aliases.zh-TW.md`

- `aliases.md:469-470`: add `--session` to the `hvibe`/`hcode` row descriptions.
- `aliases.zh-TW.md`: **backfill the two missing `herdr-vibe`/`herdr-code` rows** (existing gap — the zh-TW table skips from `svibe` at :461 to `try-sesh` at :462), including `--session`.

### 5. Light touch-ups (review only, likely no change)

- `backlog/hvibe-herdr-surfacing.md`: add a one-line "Update (2026-07): hvibe/hcode now auto-attach from outside herdr + take `--session`" note (that backlog's axis — surfacing in the herdr UI via keybinding/tv/Projects — remains open).
- `TODO.md:124-125`, `README.md:258`, `docs/this_repo/tool-managers.md:1013-1014`: no change (install facts / capability summary unchanged).

## Verification

1. **Shell syntax**: `bash -n` **and** `zsh -n` on `dot_config/shell/24_herdr.sh`.
2. **Functional (against the live server; we're inside herdr `default`)**:
   - `source ~/.config/shell/22_sesh.sh; source dot_config/shell/24_herdr.sh` (or `chezmoi apply` first), then `hvibe -h` / `hcode -h` show `--session`.
   - `hvibe --no-attach --session test -p <some repo>` → confirm the `vibe/<repo>` workspace lands in the **test** session via `HERDR_SOCKET_PATH=<test sock> herdr workspace list`, and is **absent** from `default`; then `herdr workspace close` it to clean up.
   - `hvibe --no-attach -p <repo>` (no `--session`, inside herdr) → lands in **default** (ambient). Clean up.
   - `hvibe --session nonesuch` → errors with the "start it with `herdr --session nonesuch`" hint, non-zero exit.
   - Confirm `HERDR_SOCKET_PATH` is **unchanged** in the calling shell after each run (no `export` leak).
3. **Docs**: `uv run mkdocs build --strict` passes (catches the new zh-TW page + any broken links).
4. Deploy for live use: `chezmoi apply` (or `cas`) so the interactive shell picks up the edited function.
