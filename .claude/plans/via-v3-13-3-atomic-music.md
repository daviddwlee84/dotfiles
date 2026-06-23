# Plan: smarter "Local SSH config" step in `ssh-setup-remote`

## Context

`ssh-setup-remote` (`dot_config/shell/96_ssh_setup.sh`, "Step 3: Local SSH config",
lines 187–248) currently **always appends** a fresh `Host` block to the chosen config file.
That is wrong for the case the user just hit: running `ssh-setup-remote ts_mac` where `ts_mac`
is **already** a configured Host (that is exactly why `ssh-copy-id ts_mac` reached
`100.100.100.100`). Appending a second `Host ts_mac` block produces a confusing duplicate, and
the new `IdentityFile` may not even take effect (first-match-wins per key).

We want the wizard to recognize two situations and do the right thing automatically:

1. **Adhoc new host** (`user@ip`): one-step — create a Host alias + write the block. (≈ current
   behavior, refined.)
2. **Existing host**: alias already exists but had no key configured; *add* `IdentityFile`
   (+ optional `IdentitiesOnly yes`) **into the existing block, in whichever file it lives** —
   not a duplicate stanza.

The config can be split: managed `~/.ssh/config` is an entry point that `Include
~/.ssh/config.d/*`. Locating an existing Host must **recursively follow `Include` directives**
(glob, `~`/relative/absolute). On *this* machine the live `~/.ssh/config` is the user's
pre-existing hand-curated file with **no `Include` line**, yet `~/.ssh/config.d/` exists — so
drop-ins here currently do not load (handled below).

### Decisions (confirmed)
- **Mechanism**: inline `python3` heredoc helper for parse/find/edit; shell keeps all
  interactive prompts. Fall back to current append-only flow if `python3` is absent.
- **Existing IdentityFile present**: show the block, prompt `[r]eplace / [a]dd another / [s]kip`.
- **config.d drop-in but no `Include` in `~/.ssh/config`**: detect and offer to add
  `Include ~/.ssh/config.d/*`.

## Implementation

### 1. New shell helper `_ssh_cfg_py()` in `dot_config/shell/96_ssh_setup.sh`

One POSIX-source-safe function wrapping a single `python3 - "$@" <<'PY' … PY` heredoc with a
subcommand dispatch (keeps all Include-resolution logic in one place). Returns 127 if `python3`
is missing so callers can fall back.

Python CLI (root = `$HOME/.ssh/config`, ssh_dir = its parent):
- `resolve_includes(start)` — recursive walk from `~/.ssh/config`; for each non-comment
  `Include` line, split patterns, `os.path.expanduser`, make relative patterns relative to
  `ssh_dir`, `glob.glob`, recurse; `seen` set guards loops; returns ordered file list. Reuses the
  pattern already proven in `scripts/init/dotfiles_init.py:_detect_ssh` but made recursive.
- `find <alias>` — scan resolved files for a `Host` line whose tokens contain `alias` as an
  exact token (skip `*?!` wildcard/negation patterns, matching the awk in
  `dot_config/television/cable/ssh-config.toml`). On hit, print machine-readable
  `key=value` lines for the shell: `found=1`, `file=…`, `has_identityfile=0|1`,
  `identityfile=…`, `key_present=0|1` (idempotency: exact `$key_path` already in block), plus
  the block text (for display). Exit non-zero / `found=0` when not found.
- `insert <file> <alias> <key> <action>` — rewrite the matched block: `action` ∈
  `insert` (no existing IdentityFile), `replace`, `add`. Indentation copied from the block's
  existing indented lines (fallback 4 spaces). Optional trailing `--identities-only` appends
  `IdentitiesOnly yes` if absent. Atomic write: temp file in same dir → `os.replace` →
  reapply `0o600`.
- `ensure-include` / `add-include` — report whether `resolve_includes` reaches
  `~/.ssh/config.d/`; if not, `add-include` prepends `Include ~/.ssh/config.d/*` (with a
  comment) near the top of `~/.ssh/config`, matching `dot_ssh/create_private_config` layout
  (Include-at-top so drop-ins are visible; note first-match-wins ordering).

### 2. Rework "Step 3" (lines 187–248) of `ssh-setup-remote`

Replace the unconditional append with:

1. Pick the lookup alias (default `$remote_host`).
2. `_ssh_cfg_py find "$alias"`:
   - **rc 127** → fall back to the existing append flow unchanged.
   - **found=1 (Mode B — existing)**: print "Host `$alias` already configured in `<file>`" +
     the block. If `key_present` → report "already has this key", skip. Else if
     `has_identityfile` → prompt `[r]eplace / [a]dd another / [s]kip`; map to `insert` action.
     Offer `IdentitiesOnly yes` if missing. Call `_ssh_cfg_py insert …`. Validate with
     `ssh -G "$alias"`.
   - **found=0 (Mode A — new)**: keep current prompts (alias/hostname/user/IdentitiesOnly,
     `~/.ssh/config` vs `~/.ssh/config.d/host_<alias>`, confirm, append). After writing to
     `config.d/`, run `_ssh_cfg_py ensure-include`; if it can't be reached, offer
     `_ssh_cfg_py add-include`.
3. Final "Test with: ssh `<alias>`" line unchanged (`${host_alias:-$target}`).

Keep everything POSIX-source-safe (file is in shared `dot_config/shell/`; both shells source
it). `[[ … =~ ]]` is already used in this file and works in zsh+bash.

## Mirror updates (CLAUDE.md cross-file rules)
- `docs/tutorials/setup_ssh_key_on_remote.md` + `docs/tutorials/setup_ssh_key_on_remote.zh-TW.md`:
  update the wizard "Step 5 / Add a host alias" description for the new existing-vs-new behavior;
  fix the **stale source path** `~/.config/zsh/tools/96_ssh_setup.zsh` →
  `~/.config/shell/96_ssh_setup.sh`.
- `docs/shells/aliases.md`: add the currently-missing `ssh-setup-remote` row (function, source
  `dot_config/shell/96_ssh_setup.sh`, scope shared, one-liner).

No SKILL.md / completions / tool-managers changes (no new CLI or prompt key).

## Critical files
- `dot_config/shell/96_ssh_setup.sh` — main change (helper + Step 3 rework).
- `docs/tutorials/setup_ssh_key_on_remote.md`, `…zh-TW.md` — wizard docs + path fix.
- `docs/shells/aliases.md` — new function row.
- Reference only: `scripts/init/dotfiles_init.py:_detect_ssh` (parser pattern),
  `dot_config/television/cable/ssh-config.toml` (Host-token awk), `dot_ssh/create_private_config`
  (Include-at-top layout).

## Verification
1. **Isolated harness** (don't touch real `~/.ssh`): point the Python root at a temp file via an
   env override and exercise:
   - (a) temp `config` with `Host x` and no key → `insert` adds IdentityFile with matching indent;
   - (b) temp `config` with `Include ./config.d/*` → `Host x` in a drop-in → edit lands in the
     drop-in file, not the entry point;
   - (c) `Host x` that already has IdentityFile → `replace` / `add` / `skip` each behave;
   - (d) re-run with same key → idempotent skip;
   - (e) brand-new `user@ip` → append flow; config.d-without-Include → add-include offered.
   Assert perms stay `600` and `ssh -G -F <tmp> x` parses and shows the new `identityfile`.
2. Source the file in **both** `zsh` and `bash` (no source-time error).
3. `chezmoi apply` the file; re-source; smoke `ssh-setup-remote <existing-alias>` (adds key in
   place) and `ssh-setup-remote user@<ip>` (creates alias).
4. App-level config validation per repo rule: `ssh -G <alias>` after each edit.
