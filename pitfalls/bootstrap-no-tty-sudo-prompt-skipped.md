# Bootstrap warns "Could not establish a sudo session (no TTY)" then Linuxbrew aborts

## Symptom

Fresh `chezmoi init --apply` on a Linux box where the user **does have sudo
rights** (verified by an interactive `sudo -v` working in the same shell, with
a password prompt). The bootstrap nevertheless skips the sudo session and the
Linuxbrew installer dies:

```
[yczhang@idc-server104 ~]$ sudo -v
[sudo] password for yczhang:                                  ← works fine
[yczhang@idc-server104 ~]$ sh -c "$(curl -fsLS get.chezmoi.io)" -- \
    -b "$HOME/.local/bin" init --apply "https://github.com/.../dotfiles.git"
...
mkdir: cannot create directory ‘/run/user/162000029’: Permission denied
[WARN] Could not establish a sudo session (no TTY and sudo needs a password);
[WARN] bootstrap will attempt its sudo steps anyway and they may prompt or skip.
[INFO] Installing Linuxbrew...
==> Running in non-interactive mode because `$NONINTERACTIVE` is set.
==> Checking for `sudo` access (which may request your password)...
Insufficient permissions to install Homebrew to "/home/linuxbrew/.linuxbrew" (the default prefix).
chezmoi: 00_bootstrap.sh: exit status 1
```

The two-step workaround (`chezmoi init` then `chezmoi apply` from a clean
interactive shell) **also fails** with the same WARN — running `unset
NONINTERACTIVE` in the parent shell doesn't help either, because the
bootstrap script sets `NONINTERACTIVE=1` inline for the brew installer
subprocess at [`run_once_before_00_bootstrap.sh.tmpl:175`](../run_once_before_00_bootstrap.sh.tmpl).

## Environment

Reproduces on:

- **CentOS 7** (glibc 2.17) — corporate IDC dev server
- High-UID **AD / LDAP user** (e.g. `162000029`) — first hint
- `XDG_RUNTIME_DIR=/run/user/<UID>` set by `/etc/profile.d`, but
  `/run/user/<UID>/` does not exist because `pam_systemd` did not run during
  the SSH login (the `mkdir: cannot create directory '/run/user/<UID>':
  Permission denied` line above is the smoking gun)
- `Defaults requiretty` + `tty_tickets` in `/etc/sudoers` (RHEL/CentOS default)

The combination matters — none of these alone breaks the helper. AD users
with low UIDs on the same box are unaffected because their `/run/user/<UID>`
gets created by another login session.

## Root cause

[`scripts/lib/sudo_shared.sh`](../scripts/lib/sudo_shared.sh)'s
`sudo_session_init` falls through to its interactive branch (line ~263):

```bash
printf '[%s] sudo password for %s ...' "$label" "$USER" > /dev/tty
IFS= read -rs pw < /dev/tty
```

Bash's `[[ -r /dev/tty ]]` check (line 249) calls `access(2)` against the
device node — which always succeeds on `/dev/tty` (mode 0666) regardless of
whether the calling process has a controlling terminal. **The actual `open(2)`
on `/dev/tty` happens at the redirect**, and that fails with `ENXIO` ("No
such device or address") when the chezmoi-spawned run-script subprocess has
no controlling terminal.

Why does it have no controlling terminal? Two compounding factors on this
class of box:

1. The `sudo -S -v` validation inside `_sudo_state_valid` (line 110) invokes
   PAM, which calls `pam_systemd` to ensure `/run/user/<UID>/` — that mkdir
   fails (the visible error). `pam_systemd` then tears down the session
   association in subtle ways depending on PAM stack ordering.
2. CentOS 7's `chezmoi` binary (Go) inherits stdio from its parent, but when
   it `exec`s the run-script bash interpreter, the new process group
   sometimes loses the controlling-terminal association — particularly with
   high-UID AD users where the original session never had a `pam_systemd`-
   tracked session ID to begin with.

The script's `printf > /dev/tty` redirect fails silently (no error printed —
`set -e` is suspended inside `if !` context), the function returns 1, the
WARN fires, and bootstrap proceeds. Brew's hard-wired `NONINTERACTIVE=1` +
`sudo -n -v` then can't find a fresh sudo timestamp (different tty_ticket)
and the installer aborts.

## Fix: inject password via `CHEZMOI_SUDO_PASSWORD_FILE`

`sudo_session_init` already has a non-TTY entry point built for
`fleet_apply.py` over SSH ([`sudo_shared.sh:209-246`](../scripts/lib/sudo_shared.sh)).
It works for any non-interactive context, not just remote ones.

Easiest entry point — [`scripts/apply_with_sudo.sh`](../scripts/apply_with_sudo.sh)
(also exposed as `just apply-with-sudo` for re-runs):

```bash
# First time (chezmoi binary not installed yet)
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"   # install chezmoi only
bash <(curl -fsSL https://raw.githubusercontent.com/$GITHUB_USERNAME/dotfiles/main/scripts/apply_with_sudo.sh) \
  --init "https://github.com/$GITHUB_USERNAME/dotfiles.git"

# Subsequent runs (chezmoi source already at ~/.local/share/chezmoi)
just apply-with-sudo                                  # interactive prompt
just apply-with-sudo --pass-from-env                  # reads $SUDO_PASSWORD
SUDO_PASSWORD=xxx just apply-with-sudo --pass-from-env
```

The wrapper:

1. Acquires the password (prompt / `--pass-from-file FILE` / `--pass-from-env`)
   into a 0600 tmpfile under `$TMPDIR`.
2. Validates with `sudo -S -v -p ''` — fails fast if rejected (saves a long
   apply that would otherwise abort mid-run).
3. Exports `CHEZMOI_SUDO_PASSWORD_FILE`, runs `chezmoi apply` (or
   `chezmoi init --apply` with `--init`).
4. `trap cleanup EXIT INT TERM HUP` shreds the tmpfile on any exit (use
   `--keep-file` to keep it during debugging).

What the helper inside chezmoi's run-scripts does next:

1. Reads + revalidates the file with `sudo -S -v -p ''`.
2. Moves it into the shared state dir (`$TMPDIR/chezmoi-sudo-<UID>/sudo.pass`,
   mode 0600) — the `XDG_RUNTIME_DIR` fallback to `$TMPDIR` already kicks in
   here because `/run/user/<UID>/` doesn't exist.
3. Spawns the watchdog that keeps the sudo timestamp warm (every 50 s).
4. `unset`s `CHEZMOI_SUDO_PASSWORD_FILE` in the subprocess so subsequent
   run-scripts hit the idempotent reuse branch.

Brew's `NONINTERACTIVE=1` install now sees a live sudo timestamp and proceeds.

### Manual equivalent (no wrapper)

If you can't / don't want to use the wrapper:

```bash
umask 077
printf '%s\n' 'YOUR_SUDO_PASSWORD' > ~/.cz_sudo
chmod 600 ~/.cz_sudo
export CHEZMOI_SUDO_PASSWORD_FILE=~/.cz_sudo

sh -c "$(curl -fsLS get.chezmoi.io)" -- \
  -b "$HOME/.local/bin" init --apply "https://github.com/$GITHUB_USERNAME/dotfiles.git"

shred -u ~/.cz_sudo   # destroy on completion
```

The wrapper is just this dance plus password validation + cleanup-on-signal.

## Alternative: NOPASSWD: ALL

For boxes where you'll re-run `chezmoi apply` repeatedly (and don't want to
keep injecting the password):

```bash
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/99-$USER-bootstrap
sudo chmod 440 /etc/sudoers.d/99-$USER-bootstrap
# run chezmoi
sudo rm /etc/sudoers.d/99-$USER-bootstrap   # remove when done
```

`_sudo_is_truly_passwordless` ([`sudo_shared.sh:175-177`](../scripts/lib/sudo_shared.sh))
greps `sudo -n -l` for `NOPASSWD: ALL` and short-circuits the entire helper
— no state dir, no watchdog, no `/dev/tty` open attempt. Brew's `sudo -n`
likewise just passes.

## Why `chezmoi init` + separate `chezmoi apply` does NOT work

Tempting workaround that fails:

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" \
  init "https://github.com/$GITHUB_USERNAME/dotfiles.git"   # init only, no apply
~/.local/bin/chezmoi apply                                   # apply from clean shell
```

Same WARN, same brew failure. The `apply` step still spawns
`run_once_before_00_bootstrap.sh.tmpl` as a chezmoi child process, which
hits the same `/dev/tty` open failure for the same reason. Splitting the
init/apply doesn't change which process opens `/dev/tty`.

## Why `unset NONINTERACTIVE` does NOT work

The `NONINTERACTIVE=1` printed in the brew log is **not** inherited from the
user's shell — it's set inline at
[`run_once_before_00_bootstrap.sh.tmpl:175`](../run_once_before_00_bootstrap.sh.tmpl):

```bash
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

This is intentional: the bootstrap design assumes `sudo_session_init` has
already populated the password file + spawned the watchdog. Removing
`NONINTERACTIVE=1` would just hang the brew installer waiting on a TTY prompt
that the chezmoi-spawned context can't deliver.

## Related

- [`docs/this_repo/sudo-session.md`](../docs/this_repo/sudo-session.md) — full helper API + state-dir layout, "Non-interactive password injection" section.
- [`docs/this_repo/fleet-apply.md`](../docs/this_repo/fleet-apply.md) — the canonical user of `CHEZMOI_SUDO_PASSWORD_FILE` (over SSH).
- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — sister pitfall for the same class of box when the user has **no** sudo (different fix path: `noRoot=true`).
- [`pitfalls/sudo-shared-setsid-macos.md`](sudo-shared-setsid-macos.md) — adjacent watchdog/spawn issue on a different platform.
- `CLAUDE.md` "Sudo session is shared across all run-scripts" hard invariant.
