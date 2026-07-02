# Implement TODO.md:80 — opt-in SSH-login password fallback for `fleet`

## Context

Earlier research in this session (see the "Research: sshpass..." section this plan replaces) confirmed
that `fleet` (`dot_dotfiles/bin/executable_fleet`, backed by `scripts/fleet/*.py`, using `asyncssh>=2.18`)
deliberately never uses a password for the SSH *login* itself — only for remote `sudo` (via
`CHEZMOI_SUDO_PASSWORD_FILE`). This is already documented as a known, deliberate gap:
[`pitfalls/fleet-apply-password-source-not-for-ssh-login.md`](pitfalls/fleet-apply-password-source-not-for-ssh-login.md)
and a still-open backlog item at `TODO.md:80`, triggered by a real host (`zyc_friend`, an IDC server whose
sshd has `PubkeyAuthentication no` and only offers `keyboard-interactive`/PAM auth — so even
`ssh-copy-id` doesn't help, and the host permanently shows `unreachable` in `fleet-status`).

The user asked to actually implement this now, and to decide where an `sshpass`/`expect` install recipe
would go (devtools ansible role vs elsewhere). Deep research (4 parallel explore/design agents, one of
which read `asyncssh`'s actual cached source under `~/.cache/uv/environments-v2/`) found a better answer
than either external tool: **`asyncssh` (already a hard dependency) natively supports `password=` and
`preferred_auth=` kwargs on `connect()`, including auto-answering single-prompt keyboard-interactive/PAM
challenges** — exactly `zyc_friend`'s failure mode. So the recommended fix needs **zero new external
binaries** — no `sshpass`, no `expect`, nothing to add to any ansible role or Brewfile.

The user was asked to confirm this via `AskUserQuestion` but didn't respond within the wait window, so
this plan proceeds with the recommended defaults (all were the "(Recommended)" option): asyncssh-native
implementation, a new independent `ssh_login_password_source` TOML field (kept separate from the
existing sudo-only `password_source`, since a host's SSH login password may differ from its sudo
password), and no new tool installed anywhere.

Every code-level claim below was verified directly against current file contents in this session (line
numbers are current, not estimates) — grep confirms **exactly 6** `asyncssh.connect(**_connect_kwargs(...))`
call sites in `apply.py` (lines 875, 1500, 1717, 2448, 2753, 2959) plus one each in `exec.py:257`,
`tmux.py:238`, `info.py:304`, `pueue.py:182`; `resolve_passwords()` has exactly **one** call site today
(`apply.py:3021`, inside the actual apply/update/diff executor — never called by `fleet-status`/`exec`/
`tmux`/`info`/`pueue`); and `scripts/fleet/hosts.py` has its own independent password-redaction logic
(`_cmd_list_json` ~153-164, `_cmd_describe` ~245-250) that must be mirrored for the new field or
`fleet hosts --list-json`/`--describe` will leak a plaintext SSH-login password.

## Design

### 1. `scripts/fleet/apply.py` — the only file with real logic

**`Host` dataclass** (currently lines 64-90): append three fields after the existing `sudo_password`
field, mirroring its naming:
```python
ssh_login_password_source_type: PasswordSourceType = "none"
ssh_login_password_source_arg: str | None = None
ssh_login_password: str | None = None  # populated by resolve_ssh_login_passwords()
```

**`load_hosts()`** (103-159): factor the existing inline `password_source` table-normalization (lines
134-140) into a small helper `_parse_password_source_table(raw_table, *, field_name, path, host_name) ->
tuple[PasswordSourceType, str | None]` (identical 4-way `plain`/`prompt`/`bitwarden`/`none` validation,
parameterized error-message text). Call it twice — once for `password_source` (byte-identical error text
to today), once for the new `ssh_login_password_source` table — then pass both resolved pairs into
`Host(...)`.

**Password resolution** (currently `resolve_passwords()`, 193-235, plus `_bw_get_password()`, 168-190):
extract the `plain`/`prompt`/`bitwarden`/`none` dispatch into a shared
`_resolve_one_password(h, type_, arg, *, field_name, prompt_label, console) -> str | None` helper. Then:
- `resolve_passwords()` keeps its exact contract (sudo-only, mutates `sudo_password`), now implemented by
  calling `_resolve_one_password` per host.
- New `resolve_ssh_login_passwords(hosts, console)` — same shape, mutates `ssh_login_password`, must be
  called from **every** fleet entry point that opens an SSH connection (not just apply, unlike
  `resolve_passwords`).
- Reword `_bw_get_password`'s `FileNotFoundError` hint to be field-agnostic (no longer says
  `password_source.type` specifically, since it's now shared).
- Minor, low-risk text change: the "prompt cancelled" warning gains a label (`"sudo password prompt
  cancelled"` vs today's unlabeled text) since a host can now have two independent prompts.

**New `connect_host()` helper** — the single insertion point that gives all 10 call sites the retry for
free:
```python
async def connect_host(host: Host, connect_timeout: float) -> asyncssh.SSHClientConnection:
    async with asyncio.timeout(connect_timeout):
        try:
            return await asyncssh.connect(**_connect_kwargs(host))
        except asyncssh.PermissionDenied:
            if not host.ssh_login_password:
                raise
            kwargs = _connect_kwargs(host)
            kwargs["password"] = host.ssh_login_password
            kwargs["preferred_auth"] = ("keyboard-interactive", "password")
            return await asyncssh.connect(**kwargs)
```
`_connect_kwargs()` itself (558-577) is **not modified** — it stays a pure static-config translator;
`connect_host` is the only place that knows about resolved runtime secrets and retries. Hosts without
`ssh_login_password` set see byte-identical behavior to today (the `if not ...: raise` re-raises
unchanged).

Two things verified against asyncssh's own source and worth carrying into the code as comments:
- Without a `password` kwarg, asyncssh's `password_auth_requested()`/`kbdint_auth_requested()` both
  synchronously return `None` — so today's key/agent-only first attempt never blocks/prompts even against
  a server that offers keyboard-interactive, confirming the existing path is unaffected.
- Catching only `asyncssh.PermissionDenied` is correct for the concrete `zyc_friend` case (clean
  userauth-failure rejection). A theoretical edge case (many `ssh-agent` identities + a server's low
  `MaxAuthTries` disconnecting with a generic protocol error) could surface as `ProtocolError`/
  `ConnectionLost` instead and skip the retry — ship the narrow catch for v1 (safe: never regresses
  opted-out hosts either way) and broaden only if that's observed in practice.

**Re-export via `scripts/fleet/__init__.py`**: add `connect_host` and `resolve_ssh_login_passwords` to
both the import block and `__all__`, same pattern as the existing `_connect_kwargs`/`resolve_passwords`.
Leave the file's own "eventually carve out to `_lib.py`" TODO comment alone — this feature is not that
trigger.

**`main()`** (starts ~3093): right after the existing `selected = [...]` / `if not selected: ... return 0`
block (~1380-1391) and before the `if kill_orphans:` dispatch, add one call:
```python
resolve_ssh_login_passwords(selected, console)
```
This single call covers all 6 of `apply.py`'s own downstream branches. The existing
`resolve_passwords(selected, console)` call at line 3021 (inside `_run()`, sudo-only) stays untouched —
`fleet-status`/etc. still never prompt for an unrelated sudo password.

**Migrate the 6 call sites**: replace each
`async with asyncio.timeout(connect_timeout): conn = await asyncssh.connect(**_connect_kwargs(h))`
(lines 875, 1500, 1717, 2448, 2753, 2959) with `conn = await connect_host(h, connect_timeout)`. Outer
`except (asyncssh.Error, OSError, TimeoutError)` clauses at each site stay exactly as-is —
`connect_host()` raises the same exception surface.

### 2. Four satellite files — `exec.py`, `tmux.py`, `info.py`, `pueue.py`

Each needs exactly two changes:
1. One `resolve_ssh_login_passwords(selected, ...)` call right after that file's own
   `selected = _filter_hosts(...)` line (`exec.py:790`, `tmux.py:370`, `info.py:473`, `pueue.py:378`).
2. Replace that file's own `connect_kw = _connect_kwargs(host); async with asyncio.timeout(...): conn =
   await asyncssh.connect(**connect_kw)` (`exec.py:257-258`, `tmux.py:238-239`, `info.py:304-305`,
   `pueue.py:182-183`) with `conn = await connect_host(host, connect_timeout)`, and swap the
   `_connect_kwargs` import for `connect_host` in each file's `from scripts.fleet import (...)` block.

### 3. `scripts/fleet/hosts.py` — required redaction fix (not in the original TODO sketch)

- `_cmd_list_json()` (~153-164): add `d.pop("ssh_login_password", None)` alongside the existing
  `sudo_password` pop, and mirror the `type == "plain"` redaction guard for
  `ssh_login_password_source_arg`.
- `_cmd_describe()` (~218-250): after the existing `password_source` label/print block, add the mirrored
  block for `ssh_login_password_source_type`/`_arg`, printed unconditionally (defaults to `none`) so the
  new field always appears in `fleet hosts --describe`.

### 4. Sequencing

`apply.py` (all of §1) → `__init__.py` (2-line re-export) → `hosts.py` (§3, the easy-to-forget security
fix) → the 4 satellites (§2, any order). Each step is independently checkable via `fleet hosts
--list-json` / `fleet chezmoi status` against a scratch inventory.

## Docs

- **`docs/this_repo/fleet-apply.md`**: new table `### SSH login password sources (opt-in fallback)`
  right after the existing "Password sources" table (374-381), same 4-column shape, explicit note that
  it's independent of `password_source` and that `none` (default) = today's exact behavior. New top-level
  section `## How the SSH login password reaches asyncssh` as a sibling right after "How sudo password
  reaches the remote" (394-417) — explain the in-process kwarg path (no file write, no stdin, contrast
  with the sudo path just above it) and the retry sequence. Append a clause to the `unreachable` row's
  Recovery cell in the State matrix (~line 255) pointing at the new section.
- **`dot_config/fleet/create_private_machines.toml.tmpl`**: rewrite the header comment (lines 8-13) to
  describe the new opt-in field instead of stating the limitation as unconditional; append a 6th example
  `[[hosts]]` block (after the existing 5, following line 86) modeled on `zyc_friend` — explicit
  connection (no `ssh_alias`), `ssh_login_password_source = { type = "bitwarden", item = "..." }`, with a
  comment explaining it's independent of `password_source` and opt-in only.
- **`pitfalls/fleet-apply-password-source-not-for-ssh-login.md`**: targeted edits, not a rewrite. Add a
  "Status: conditionally fixed 2026-07-02 (opt-in) — see `fleet-apply.md` § SSH login password sources"
  line under the title. Fix the "Root cause" section's inaccurate claim that SSH login uses `subprocess`
  → `ssh -o BatchMode=yes` — it's actually a single in-process `asyncssh.connect()` call, no subprocess.
  Update the Stage/Auth-mechanism table's SSH-login row to note the opt-in exception. Correct the "Gotcha"
  point that says "even sshpass wouldn't trivially work" — the shipped mechanism is asyncssh-native (not
  sshpass) and does handle the PAM-only case natively.
- **`docs/tools/fleet-hosts.md`**: update the "prompts for password" troubleshooting bullet (~135-139) to
  point at the new opt-in field alongside the existing `ssh-copy-id` advice; extend the redaction note
  (~100) to cover both fields; update the "Preview pane contents" example (~83) to show the new
  `ssh_login_password_source` line, matching `_cmd_describe`'s now-unconditional output.
- **`docs/this_repo/tool-managers.md`**: no-op, explicitly — no new tool is installed by this feature.
- **`docs/this_repo/fleet-apply.zh-TW.md`**: leave untouched (this repo's i18n setup falls back to
  English for untranslated sections; not blocking this feature on translation).

## Backlog + TODO cleanup

- Create **`backlog/fleet-ssh-password-login.md`** following the exact template in `backlog/README.md`
  and the `backlog/fleet-exec.md` precedent (a `[?/M]` P?-tagged, multi-option-research item that ships
  gets a `**Status**: Done <date>` line + a `## Resolution` section, not the in-progress
  `## Decision (if any)` heading). Content: Context (restate the `zyc_friend` trigger), Investigation
  (the asyncssh source citations — `PermissionDenied` vs `ProtocolError` nuance, kbdint auto-answer
  heuristic), Options considered (asyncssh-native vs sshpass subprocess vs expect subprocess, with the
  zero-new-deps rationale for the winner), Resolution (what shipped, dated 2026-07-02). Per the
  `fleet-exec.md` precedent, **do not** add this to the Index table in `backlog/README.md` — Done items
  are omitted there.
- Delete the `TODO.md:80` bullet in full (this repo's convention: resolved items are deleted, not checked
  off — confirmed via the `fleet-exec` precedent, which is fully absent from current `TODO.md`). No other
  structural change needed to the `## P3 — Someday / nice to have` section.

## Verification

Per this repo's "Validate app configs with the app, not just syntax" rule — use `fleet hosts --list-json`
/ `fleet chezmoi status`, not just a syntax check of the TOML/Python.

1. **Static checks first**: `fleet hosts --list-json` and `fleet hosts --describe <name>` against a
   scratch `machines.toml` with the new field set — confirms parsing (§1) and redaction (§3) without
   needing a live connection.
2. **Local Docker simulation** (this repo already has Docker smoke-test infra, so this is low-effort):
   spin up a throwaway container (ubuntu + `openssh-server`) with `sshd_config` forced to
   `PubkeyAuthentication no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication yes`,
   `UsePAM yes` — this reproduces `zyc_friend`'s exact reported
   `Authentications that can continue: gssapi-keyex,gssapi-with-mic,keyboard-interactive` (no plain
   `password` method), which specifically exercises asyncssh's kbdint auto-answer path rather than the
   simpler `password` method.
   - **Negative control first**: point a scratch inventory at the container *without*
     `ssh_login_password_source` set → confirm it still shows `unreachable` (proves opt-in-only, zero
     regression for the default case).
   - Add the field with the correct password → confirm the host gets *past* the connect phase (state
     becomes `no-chezmoi`/`not-init` since the container has no chezmoi — the point is proving auth
     succeeded).
   - Wrong password → confirm a clean, fast failure within `connect_timeout` (no hang).
   - 2+ scratch hosts, one with `type = "prompt"` → confirm exactly one synchronous `getpass()` prompt at
     startup, before any per-host connection output (validates the parallel-safety / no-mid-connection-TTY
     constraint).
   - Teardown via `docker stop`/`rm`; this is a manual verification rig, not a permanent addition to
     `tests/smoke/` or `just docker-test`.
3. If the real `zyc_friend` host is reachable and the user is willing, the highest-fidelity check is
   adding `ssh_login_password_source` to its real inventory entry (via `bitwarden` or `prompt`, not
   `plain`) and running `just fleet-status --hosts zyc_friend` directly — the actual documented trigger
   host from the pitfall doc.
