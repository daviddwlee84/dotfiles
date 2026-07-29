# fleet hosts — picker for SSH'ing into fleet-configured machines

`fleet hosts` is the TV-style picker for the fleet inventory at
`~/.config/fleet/machines.toml`. It mirrors the
[`ssh-config` cable](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/ssh-config.toml)
(`tv ssh-config`) but reads fleet's TOML instead of `~/.ssh/config`, so hosts
with explicit `hostname` / `user` / `port` / `identity_file` (no ssh_alias)
are reachable too.

Sister tools: [`fleet exec`](fleet-exec.md) for cross-host ad-hoc commands,
[`fleet pueue`](pueue.md) for queue probing,
[`fleet chezmoi apply`](../this_repo/fleet-apply.md) for the deploy workflow.
All four read the same inventory via `scripts/fleet/apply.py:load_hosts()`.

## Install

Deployed automatically by chezmoi:

- `~/.dotfiles/bin/fleet` — the umbrella binary (dispatches `fleet hosts`)
- `~/.config/television/cable/fleet-hosts.toml` — the TV channel
- `~/.local/share/chezmoi/scripts/fleet/hosts.py` — the implementation
  (resolved at runtime via `chezmoi source-path`, so the cable / binary find
  the latest version even on hosts where you haven't run `chezmoi apply` yet)

No separate install step. `tv` (television) is pulled in by the devtools role
and is what powers the picker UX.

## Three entry points

| Form | What it does |
|------|--------------|
| `tv fleet-hosts` | Open the picker directly via television. Enter → SSH. |
| `fleet hosts` | Same picker via the fleet umbrella (execs `tv fleet-hosts`). |
| `fleet hosts NAME` | Skip the picker — SSH straight into `NAME` (lands in tmux; see below). |
| `fleet hosts --list` | Plain host names, one per line. Scriptable. |
| `fleet hosts --list-tsv` | `name<TAB>target<TAB>kind` (the cable's source). |
| `fleet hosts --list-json` | Full inventory as JSON (plain passwords redacted). |
| `fleet hosts --describe N` | Multi-section preview block for `N` (the cable's preview). |
| `fleet hosts --probe N` | BatchMode SSH probe of `N` (the cable's Alt+T action). |

Direct invocation (`fleet hosts NAME`) uses `os.execvp("ssh", ...)`, so your
terminal becomes the SSH session — no wrapper subprocess, no lost TTY
attributes. Behaviour matches Enter inside the picker.

## You land in tmux by default

`fleet hosts NAME` (and Enter in the picker) runs `ssh -t` with a remote command
that attaches to a tmux session named `fleet`, creating it if absent:

```sh
command -v tmux >/dev/null 2>&1 && exec tmux new -A -s fleet || exec "${SHELL:-/bin/sh}" -l
```

`tmux new -A -s` is attach-if-exists / create-otherwise. The point is
resumability: drop the connection — laptop sleeps, Wi-Fi flips, an iPad
backgrounds the terminal app — and the next `fleet hosts NAME` lands back in the
same session with the work still running. Without it every disconnect is a lost
shell.

| Flag | Effect |
|------|--------|
| *(default)* | Attach-or-create session `fleet` |
| `--tmux-session NAME` | Use a different session name |
| `--no-tmux` | Plain login shell — argv is identical to the pre-tmux behaviour |

Hosts without tmux installed fall through to a login shell, so this is safe to
leave on for a mixed fleet. `exec` in both branches means the SSH session ends
when tmux (or the shell) does, rather than leaving a wrapper behind.

The tv cable inherits all of this for free — its Enter action shells out to
`fleet hosts '{name}'`, so there is no second copy of the ssh invocation to keep
in sync.

`local = true` hosts are hidden from `--list-tsv` (you can't SSH into
yourself). They still appear in `--list` / `--list-json` for scripts that
want the full inventory. `--include-local` overrides for `--list-tsv` too.

## Keybindings (inside the picker)

| Key | Action |
|-----|--------|
| `Enter` | SSH into the selected host (`fleet hosts NAME`) |
| `Alt+T` | BatchMode SSH probe — does passwordless login actually work? |
| `Alt+S` | `fleet chezmoi status --hosts NAME` (readiness probe for one host) |
| `Alt+I` | `fleet info --hosts NAME` (OS / CPU / memory / disk snapshot) |
| `Alt+P` | `fleet pueue --hosts NAME` (queue summary for one host) |
| `Ctrl+/` | Toggle preview panel (TV builtin) |

The `Alt+` namespace is used (rather than `Ctrl+letter`) to avoid collisions
with tmux's root-table bindings — see
[CLAUDE.md keybinding rule](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md).

## Preview pane contents

`fleet hosts --describe NAME` (which the cable shells out to for every
cursor move) prints four sections:

```
# host: lab-box        (defined in: /Users/dwlee/.config/fleet/machines.toml)

connection:
  ssh_alias       lab-box
  user            (from ssh_config)
  hostname        (from ssh_config)
  port            (from ssh_config)
  identity_file   (from ssh_config)

fleet metadata:
  local                false
  no_root_machine      false
  chezmoi_path         auto
  password_source      bitwarden (item=ssh-lab-box-sudo)
  ssh_login_password_source  none
  extra_env            (none)

ssh -G 'lab-box' (resolved by ssh_config):
  hostname 192.0.2.42
  user dwlee
  port 22
  identityfile /Users/dwlee/.ssh/id_ed25519
  proxyjump bastion.example.com

local key check (offline):
  [OK]   /Users/dwlee/.ssh/id_ed25519
```

- The `ssh -G` block is omitted for hosts that don't use an `ssh_alias` —
  for those, the explicit fields in the `connection:` section already are
  the resolved values.
- **Both `password_source` and `ssh_login_password_source` deliberately
  redact `type = "plain"` values**. The TOML file itself is 0600, but the
  preview output scrolls into logs / screenshots; the type label suffices
  for triage.

## Subset selection from the picker

TV is single-select. For multi-host fan-out, drop back to the underlying
fleet commands with explicit `--hosts`:

```bash
fleet hosts --list                # see what's available
fleet exec --hosts self,ts_nas -- pueue --version
fleet info --hosts production_a,production_b
```

`Ctrl+E`/multi-select pickers are out of scope here — see the
[plan file](https://github.com/daviddwlee84/dotfiles/blob/main/.claude/plans/scripts-fleet-fleet-hazy-boole.md)
for the future-work list.

## Exit codes

| Mode | Exit code |
|------|-----------|
| `--list*` / `--describe` / picker (no SSH happened) | `0` |
| `fleet hosts NAME` (passes to `ssh`) | whatever `ssh` returned |
| `fleet hosts NAME` on a `local = true` host | `0` (no-op) |
| `fleet hosts NAME` on an unknown host | `2` |
| `--probe NAME` | `0` = passwordless OK; `255` = unreachable / auth fail; other = remote command failed |
| Picker fallback when `tv` missing, user aborts | `0` if empty input, `130` on Ctrl-C, `2` on bad index |

## Troubleshooting

- **`tv fleet-hosts` shows no rows**: run `fleet hosts --list-tsv` directly.
  If output is empty, every host has `local = true` (picker hides them).
  Override with `fleet hosts --list-tsv --include-local`.
- **`fleet hosts NAME` prompts for password**: `fleet hosts NAME` itself is a
  real interactive `ssh` process (via `os.execvp`), so it happily handles a
  password prompt on its own. The symptom matters for the *other* fleet
  subcommands (`fleet chezmoi status`/`apply`, `fleet exec`/`tmux`/`info`/
  `pueue`) — those use asyncssh and default to non-interactive key/agent
  auth only, so a password prompt there means the connection will fail. Fix
  with `ssh-copy-id`, agent forwarding, or the 1Password SSH agent where
  possible; if the remote flatly disallows pubkey auth, set the opt-in
  `ssh_login_password_source` field instead — same fix as
  [`fleet chezmoi apply` unreachable hosts](../this_repo/fleet-apply.md#ssh-login-password-sources-opt-in-fallback).
- **Preview pane shows `(ssh -G unavailable or returned nothing)`**: the
  alias isn't in `~/.ssh/config` (or its includes). Either add it, or
  switch the host entry to explicit `hostname`/`user`/`port` fields.
- **Alt+S/I/P hangs**: the underlying `fleet chezmoi status` /
  `fleet info` / `fleet pueue` is making one SSH connection — usually
  fast, but a slow remote will block the picker. Press Enter at the
  `[Press Enter to exit]` prompt to return.

## Cross-file invariants

Adding new actions, flags, or output schemas requires touching:

1. `scripts/fleet/hosts.py` — primary implementation
2. `dot_dotfiles/bin/executable_fleet` — USAGE block + `_dispatch_hosts`
3. `dot_config/television/cable/fleet-hosts.toml` — picker bindings + preview
4. `docs/this_repo/fleet-apply.md` — subcommand row
5. `docs/tools/fleet-hosts.md` — this page

`_ssh_argv()` in `hosts.py` mirrors the precedence of `_connect_kwargs()` in
`apply.py` (ssh_alias wins over explicit fields). If you change one,
update the other.

The `password_source_arg` redaction rule for `type = "plain"` lives in two
places: `_cmd_describe()` (preview text) and `_cmd_list_json()` (JSON
dump). Both must stay in sync.
