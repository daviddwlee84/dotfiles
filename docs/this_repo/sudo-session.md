# Shared sudo session for `chezmoi apply`

All three `run_*` scripts (`run_once_before_00_bootstrap.sh.tmpl`, `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`, `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`) share a single sudo session via `scripts/lib/sudo_shared.sh`. The user is prompted **once** at the very start of `chezmoi apply` and every downstream script reuses the cached credential silently.

> **Hard rule for new run-scripts**: do NOT re-implement `sudo -k` / `sudo -v` / TTY-read logic. Call the shared helper instead.

## How it's wired

- Helper lives at `scripts/lib/sudo_shared.sh` (plain bash, ~270 lines). It is **never deployed** — `scripts/**` is in `.chezmoiignore.tmpl`.
- Each `run_*.sh.tmpl` inlines the helper at render time via `{{ include "scripts/lib/sudo_shared.sh" }}` — no runtime sourcing, no path lookup back to the source tree.
- A template-time `NEED_SUDO` flag (`1`/`0`) short-circuits the whole mechanism when no script in the flow will touch sudo (e.g. `noRoot=true` on Linux, or macOS without `installBrewApps`/`installInputMethod`).

## Runtime state

Lives under `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/` (mode 0700; falls back to `${TMPDIR:-/tmp}/chezmoi-sudo-$UID/` when `$XDG_RUNTIME_DIR` is unset):

| File | Mode | Contents |
|------|------|----------|
| `sudo.pass` | 0600 | raw password + `\n`, piped into `sudo -S` by `sudo_run` |
| `ansible-become.yml` | 0600 | `ansible_become_password: "…"` YAML for `ansible-playbook -e @file` |
| `keepalive.pid` | 0600 | detached watchdog PID |
| `chezmoi.pid` | 0600 | ancestor chezmoi PID the watchdog watches |

## Cleanup model

Hybrid, because per-script `trap … EXIT` would wipe state before the *next* script can reuse it:

- Signal traps on `INT`/`TERM`/`HUP` → `sudo_session_abort` kills the watchdog + `rm -rf`s the state dir. User Ctrl+C never leaves the secret on disk.
- End-of-flow cleanup → the watchdog (detached via `setsid`) watches the chezmoi ancestor PID. When chezmoi exits, the watchdog self-terminates and `rm -rf`s the state dir. Refreshes the TTY sudo timestamp every 50 s so cask pkg installers (`sudo /usr/sbin/installer`) find a live ticket.

## Public API

All three run-scripts use these:

| Function | Purpose |
|---|---|
| `sudo_session_init [label]` | Idempotent: if state valid re-exports env vars; else prompts once on `/dev/tty`, validates, writes files, spawns watchdog. Returns non-zero when neither passwordless nor TTY-interactive. Call this BEFORE any sudo. |
| `sudo_run <cmd ...>` | Thin wrapper: `sudo -S -p '' -- "$@" <sudo.pass` — pipes cached password, never puts it in argv. Falls back to plain `sudo` when passwordless. Use for bootstrap's `apt-get` calls. |
| `sudo_session_skip_reason` | Branch helper. Prints `"cached"` / `"passwordless"` / `"non-interactive"` / `""`. Used by ansible + brew scripts to pick between `-e @file`, `""` flags, or manual-instruction fallback. |
| `sudo_session_warm_cache` | Refreshes the current TTY's sudo timestamp with the cached password. Call before tools like `brew bundle` whose cask pkg installers invoke `sudo` internally and rely on timestamp caching rather than accepting a piped password. |

**Exports on success**: `CHEZMOI_SUDO_STATE_DIR`, `CHEZMOI_SUDO_PASS_FILE`, `CHEZMOI_ANSIBLE_BECOME_FILE`, `CHEZMOI_SUDO_KEEPALIVE_PID`.

## Non-interactive password injection (`CHEZMOI_SUDO_PASSWORD_FILE`)

Used by remote orchestrators that have no TTY at the consuming end — currently
[`scripts/fleet_apply.py`](../../scripts/fleet_apply.py) over SSH.

When `sudo_session_init` is called and:

1. The shared state dir is **not** already populated, AND
2. Sudo is **not** passwordless, AND
3. `CHEZMOI_SUDO_PASSWORD_FILE` env var points to a readable file containing
   the password (one line, optional trailing `\n`),

then the file is read, validated with `sudo -S -v -p ''`, and adopted into the
shared state dir exactly as if it had been entered interactively. The watchdog
spawns the same way; subsequent run-scripts hit the cached-state branch and
never see the env var (it's `unset` after adoption).

If the password is rejected by sudo, init fails with a clear stderr message
instead of silently falling through to the TTY branch.

The orchestrator on the controller side is responsible for placing that 0600
file on the remote and cleaning it up — see
[`docs/this_repo/fleet-apply.md`](fleet-apply.md) for the contract.

## Adding a new sudo surface in a run-script

1. `{{ include "scripts/lib/sudo_shared.sh" }}` near the top of the template.
2. Decide the `NEED_SUDO` template flag for your script (mirror the conditions in existing run-scripts).
3. Call `sudo_session_init "yourlabel"`; branch on the return code + `sudo_session_skip_reason`.
4. Run privileged commands via `sudo_run …` (simple cases) or pass `-e @$CHEZMOI_ANSIBLE_BECOME_FILE` to ansible.

## Do NOT

- Run `sudo -k` (it invalidates the shared cache for the entire flow).
- Register a `trap … EXIT` that removes state (next run-script needs it).
- Read the password into a shell variable and leave it there — always via `sudo -S <file`, never as an env var or command argument.
