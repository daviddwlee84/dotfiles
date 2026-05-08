# atuin — magical shell history

[atuin](https://atuin.sh) replaces your shell history with a SQLite database
that records exit code, duration, working directory, hostname, and session
per command. Optional end-to-end-encrypted sync across hosts.

## Why we use it

- **Cross-shell history** — same SQLite db at `~/.local/share/atuin/history.db`
  is read by both bash and zsh on any host where atuin is installed. Your
  fancy `ffmpeg` one-liner from yesterday in zsh shows up when you `Alt+R`
  search from bash today.
- **Context-aware filtering** — atuin's TUI (`Ctrl+R` on bash, `Alt+R` on
  zsh & bash) lets you toggle between global / current-session / current-host
  / current-directory scopes with `Ctrl+R` inside the picker.
- **Exit-code aware** — failed commands are visually distinct in the TUI.
- **No vendor lock-in** — local-only by default. Sync server is optional and
  self-hostable.

## Install

Auto-installed by `chezmoi apply` via the [`atuin` ansible role](https://github.com/daviddwlee84/dotfiles/tree/main/dot_ansible/roles/atuin/tasks/main.yml):

| Platform | Installer | Binary location |
|----------|-----------|-----------------|
| macOS    | `brew install atuin` | `/opt/homebrew/bin/atuin` (Apple Silicon) / `/usr/local/bin/atuin` (Intel) |
| Linux    | `curl … https://setup.atuin.sh \| sh -s -- --non-interactive` | `~/.atuin/bin/atuin` |

The Linux installer is invoked with `ATUIN_NO_MODIFY_PATH=1` so it does
**not** edit your shell rc files. PATH wiring + `atuin init` happens via
the dotfiles directly:

- `dot_config/shell/15_atuin.sh` — shared (zsh + bash); adds `~/.atuin/bin`
  to PATH on Linux, runs `atuin init zsh` on zsh, registers the `Alt+R`
  bind on bash.
- `dot_bashrc.tmpl` step 8 — runs `atuin init bash --disable-up-arrow`
  (ble.sh owns up-arrow).

## Keybindings (cross-shell asymmetry — read this)

| Key | Shell | Action | Why |
|-----|-------|--------|-----|
| `Ctrl+R` | **bash** | atuin TUI | atuin's default bash bind; longstanding |
| `Ctrl+R` | **zsh**  | fzf-history-widget (NOT atuin) | Preserve fzf muscle memory + OMZ integration |
| `Alt+R`  | bash + zsh | atuin TUI | Cross-shell parity — same key opens atuin on both |
| `Up`     | bash | ble.sh history | atuin init runs with `--disable-up-arrow` |
| `Up`     | zsh  | OMZ history-substring-search | atuin init runs with `--disable-up-arrow --disable-ctrl-r` |

The `Ctrl+R` asymmetry is intentional. Rationale:

- bash has no fzf-history-widget equivalent we use; atuin is strictly better
  there, so it gets the prime keybind.
- zsh users have years of muscle memory on `Ctrl+R` → fzf, and fzf's
  history search composes cleanly with our other zsh widgets (tools-picker,
  sesh, etc. via OMZ fzf plugin). Forcing atuin onto `Ctrl+R` here would
  break that integration.
- `Alt+R` works the same on both shells and is mnemonic (**R**ecall).

If you prefer atuin on `Ctrl+R` everywhere (one-shell users), edit
`dot_config/shell/15_atuin.sh` and remove `--disable-ctrl-r` from the
zsh init line.

## Local-only by default

Out of the box, atuin runs in **local-only mode**: history is recorded to
`~/.local/share/atuin/history.db` and never leaves the machine. No account,
no network calls, no telemetry.

If you only want fancier per-host history with TUI search, you're done.

## Opt-in sync (manual)

To share history across hosts via end-to-end-encrypted sync:

```bash
# 1. Pick a sync server. Either:
#    a) Free tier on api.atuin.sh (default)
#    b) Self-hosted — see https://docs.atuin.sh/cli/self-hosting/

# 2. Register an account (only once, on first host)
atuin register -u <username> -e <email>
# (you'll be prompted for a password and shown your encryption key — SAVE IT)

# 3. On every other host, log in with the same key
atuin login -u <username>
# (paste the encryption key from step 2 when prompted)

# 4. Trigger the first sync
atuin sync
```

**Persisting credentials across `chezmoi apply`** — `atuin login` writes
session state to `~/.local/share/atuin/session` (already gitignored by atuin
itself) and the server config to `~/.config/atuin/config.toml`. Neither is
managed by chezmoi, so they survive re-apply. The encryption key itself is
NOT stored anywhere on disk in cleartext after `login` — losing it means
losing access to your synced history.

For automated provisioning across the fleet (so a new host inherits sync
without manual prompts), put the credentials in your `secrets.zsh` /
`secrets.sh` (untracked) and call `atuin login` from there guarded by
`atuin status | grep -q 'logged in' || atuin login -u … -p … -k …`.

## Importing existing history

```bash
atuin import auto    # auto-detect bash / zsh / fish history files
# or pick one:
atuin import zsh
atuin import bash
```

Run on each host once. Idempotent — re-running won't duplicate entries.

## Common subcommands

| Command | What |
|---------|------|
| `atuin search <query>` | CLI search (no TUI; great for scripts) |
| `atuin stats` | Most-used commands, per-day frequency, etc. |
| `atuin status` | Sync state, account info, db size |
| `atuin sync` | Force sync now |
| `atuin doctor` | Diagnose install / config issues |
| `atuin update` | Self-upgrade (Linux installer path; macOS uses brew) |

## Upgrade

| Host | Path |
|------|------|
| macOS | `brew upgrade atuin` (covered by `just upgrade-brew`) |
| Linux | `just upgrade-atuin` → `atuin update` (falls back to re-running `setup.atuin.sh`) |

`just upgrade-all` covers both via the categorised dispatch.

## Admin visibility and audit boundaries

Atuin is a personal shell history tool, not a server audit system.

If sync is enabled, Atuin uploads end-to-end encrypted history to the
sync server. The server operator should not be able to inspect users'
command history because synced history is encrypted with a key that
never leaves the user's machine. On the local machine, a privileged
administrator may be able to inspect a user's shell history files or
Atuin database, but those records are user-space convenience data, not
reliable audit evidence — the user owns the file and can delete or
edit it.

Traditional shell history is even more unreliable for auditing. Users
can change `HISTFILE`, disable history persistence, filter entries with
`HISTIGNORE`/`HISTCONTROL`, or use `set +o history`. History files can
also be incomplete because of multi-session race conditions, delayed
flushing, truncation, or manual edits.

For operational auditing on a multi-user server, use system-level data
sources instead:

- Login / session records: `last`, `lastlog`, `journalctl _COMM=sshd`,
  `/var/log/auth.log` (Debian) or `/var/log/secure` (RHEL).
- Privilege escalation: `journalctl _COMM=sudo`, sudoreplay (when
  configured).
- Process accounting: `acct` / `psacct`, `lastcomm`.
- Linux audit framework: `auditd` + `auditctl` + `ausearch` +
  `aureport`.

For the full audit-source tour with comparison tables, helpers, and the
opt-in `auditd` ansible role, see
[**System admin → Atuin vs audit**](../sysadmin/atuin-vs-audit.md) and
the [audit hierarchy overview](../sysadmin/README.md).

## Related

- [Zsh keybindings & keys-picker](../shells/keybindings.md) — full repo-wide
  keybindings table; atuin's `Alt+R` bind is documented there too.
- [Emacs-style line editing origin](../shells/emacs-line-editing.md) — why
  `Ctrl+R` is the historical "reverse search" key in the first place
  (Readline lineage).
- [Bash bootstrap](../shells/bash.md) — load order; atuin init runs at
  step 8, AFTER `15_atuin.sh` is sourced by `load_modular_dir` (step 7),
  hence the deferred-bind via `PROMPT_COMMAND` for `Alt+R`.
- [Shell history reference](../shells/history.md) — bash/zsh native
  history files, env vars, multi-user audit on a server, how atuin's
  SQLite store relates to the plain-text files.
- Upstream docs: <https://docs.atuin.sh>
- Upstream repo: <https://github.com/atuinsh/atuin>
