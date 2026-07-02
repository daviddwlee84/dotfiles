# fleet: opt-in SSH-login password fallback

**Status**: Done 2026-07-02
**Effort**: M
**Related**: `TODO.md` (entry removed) · `scripts/fleet/apply.py` (`connect_host`,
`resolve_ssh_login_passwords`, `Host.ssh_login_password_source_*`) ·
`docs/this_repo/fleet-apply.md` § SSH login password sources ·
`pitfalls/fleet-apply-password-source-not-for-ssh-login.md`

## Context

`fleet` (`dot_dotfiles/bin/executable_fleet`, backed by `scripts/fleet/*.py`,
using `asyncssh>=2.18`) has always authenticated SSH logins with key/agent
auth only — `password_source` in `~/.config/fleet/machines.toml` only ever
fed the REMOTE `sudo` password (via `CHEZMOI_SUDO_PASSWORD_FILE`), never the
SSH transport itself. Discovered 2026-05-08 on `zyc_friend`, an IDC server
whose sshd has `PubkeyAuthentication no` and only offers
`keyboard-interactive`/PAM auth (`Authentications that can continue:
gssapi-keyex,gssapi-with-mic,keyboard-interactive` — `publickey` absent). Even
`ssh-copy-id` doesn't help: it succeeds at depositing the key (it runs over
`keyboard-interactive` itself) but proves nothing about future logins, which
still get rejected. The host permanently showed `unreachable` in
`fleet-status`. Documented as a known gap in
`pitfalls/fleet-apply-password-source-not-for-ssh-login.md` and deferred as
`TODO.md:80` with a design sketch assuming `sshpass` would be needed.

## Investigation

Read `asyncssh`'s actual cached source (`~/.cache/uv/environments-v2/`) rather
than assuming from docs alone:

- `connection.py` (`try_next_auth`, ~3663): when the client's auth-method
  list is exhausted, asyncssh raises exactly `asyncssh.PermissionDenied` —
  this already happens today at every one of fleet's connect sites (caught
  generically by the existing `except (asyncssh.Error, OSError,
  TimeoutError)`, since `PermissionDenied` is an `asyncssh.Error` subclass).
- `connection.py` (`password_auth_requested`/`kbdint_auth_requested`,
  ~3804-3811 / ~3855-3874): without a `password=` kwarg, both synchronously
  return `None` — so a key/agent-only connect attempt never blocks or
  prompts even against a server that offers keyboard-interactive. Confirms
  the existing default path is unaffected by adding this feature.
  `connection.py` (`kbdint_challenge_received`, ~6255-6260): **with**
  `password=` set, asyncssh auto-answers a keyboard-interactive challenge
  that has exactly one prompt whose text contains "password"/"passcode"
  (case-insensitive) — exactly what PAM presents, and exactly `zyc_friend`'s
  case.
- `connection.py` (`_preferred_auth`, ~2574-2580): `preferred_auth=(...)`
  filters the server's advertised auth-method list down to only the given
  methods — passing `("keyboard-interactive", "password")` on the retry
  skips a guaranteed-to-fail pubkey re-offer.
- Open risk, not fully resolved: a client with many `ssh-agent` identities
  hitting a server with a low `MaxAuthTries` could get disconnected with a
  generic `SSH2_DISCONNECT_PROTOCOL_ERROR` (→ asyncssh `ProtocolError`, not
  `PermissionDenied`) instead of the clean userauth-failure rejection
  `zyc_friend` produces — the shipped retry only catches
  `PermissionDenied`. Safe either way (opted-out hosts never see the retry
  branch), but real-world confirmation on more hosts would be useful before
  broadening the except clause.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. `sshpass -f` subprocess shell-out | Well-known tool; matches the original TODO sketch | New binary dependency (though `sshpass` turned out to already be a plain `homebrew/core` formula + apt/yum package — no tap needed); defaults to the `password` auth method only, so PAM-only sshds like `zyc_friend` need the extra `-o PreferredAuthentications=keyboard-interactive,password` flag; plaintext password still has to hit a file/fd for sshpass to read; architecturally bolts a subprocess onto an otherwise pure-asyncio codebase |
| B. `expect`-based interactive automation | Handles arbitrary prompts, even multi-step/2FA flows; preinstalled on macOS (`/usr/bin/expect`), though not guaranteed on minimal Linux images | New binary + Tcl dependency on Linux; a whole extra script to write/maintain; overkill for a single password prompt |
| C. asyncssh native `password=`/`preferred_auth=` kwargs (chosen) | Zero new dependencies (`asyncssh>=2.18` already required); in-process, no subprocess/pty; natively auto-answers single-prompt keyboard-interactive/PAM challenges — exactly `zyc_friend`'s case; trivially async-parallel-safe | Retry-exception matching (`PermissionDenied` vs a possible `ProtocolError`/`ConnectionLost` under heavy `MaxAuthTries` pressure) needs more real-world hosts to fully validate; narrower community documentation than sshpass for this exact use case |

## Resolution (2026-07-02)

Shipped option C. Added an independent `ssh_login_password_source` TOML
field (same 4-way `plain`/`prompt`/`bitwarden`/`none` schema as the existing
sudo-only `password_source`, kept separate since a host's SSH login password
may differ from its sudo password). New `connect_host()` helper in
`scripts/fleet/apply.py` tries key/agent auth first always (unchanged
default), and on `asyncssh.PermissionDenied` retries once with
`password=host.ssh_login_password` +
`preferred_auth=("keyboard-interactive", "password")` — but only for hosts
that set the new field; every other host's behaviour is byte-identical to
before this shipped. `connect_host()` replaced the previous
`asyncssh.connect(**_connect_kwargs(...))` call at all 6 sites in
`apply.py` plus one each in `exec.py`/`tmux.py`/`info.py`/`pueue.py` (10
total), so all fleet subcommands got the fallback for free from one shared
helper. `scripts/fleet/hosts.py`'s `--list-json`/`--describe` redaction logic
was mirrored for the new field (an easy-to-miss gap not in the original TODO
sketch — `sudo_password` was already redacted, `ssh_login_password` was not).
No ansible role, Brewfile, or `tool-managers.md` entry needed — nothing new
was installed anywhere.

## References

- `pitfalls/fleet-apply-password-source-not-for-ssh-login.md` — the original
  bug report + now-updated fix section
- `docs/this_repo/fleet-apply.md` §§ "SSH login password sources", "How the
  SSH login password reaches asyncssh"
- `dot_config/fleet/create_private_machines.toml.tmpl` example 6
