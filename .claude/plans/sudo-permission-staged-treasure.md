# Sudo: prompt once, share across the whole `chezmoi apply` flow

## Context

Today `chezmoi apply` on Linux (and partially on macOS) spreads sudo password needs across three independent shell processes:

| Script | Sudo usage | Current prompt behaviour |
|---|---|---|
| `run_once_before_00_bootstrap.sh.tmpl` | direct `sudo apt-get update` / `install -y build-essential libffi-dev …` at L117, 118, 159 | No helper — relies on native sudo cache; if expired, prompts inline during apt calls |
| `run_onchange_after_20_ansible_roles.sh.tmpl` | `ansible-playbook` with `become: true` tasks across 17 roles | **Has its own prompt-once logic** at L230–247: `sudo -k` → `sudo -n true` probe → TTY read → 0600 tmpfile → `-e @file` |
| `run_onchange_after_30_brew_bundle.sh.tmpl` | macOS only: pkg-based cask installers invoke `/usr/sbin/installer` | `sudo -v` pre-auth at L79–86 (5-minute timestamp cache only) |

Consequences:

1. The ansible script's `sudo -k` at L230 **throws away** any bootstrap-era sudo cache, forcing a second prompt.
2. Bootstrap's own `sudo apt-get` lines have no pre-auth — they can prompt mid-script if the OS sudo timestamp lapsed.
3. macOS cask installers and ansible's `input_method` role can produce a third prompt outside the existing tmpfile window.
4. The "is sudo even going to be needed?" decision is made independently by each script, rather than answered once at flow start.

Goal: user enters the password **once** at the very start of the flow, every downstream script reuses it silently, and the secret never lives on disk beyond the flow's lifetime.

## Design

### 3.1 Shared helper: `scripts/lib/sudo_shared.sh`

A plain POSIX-ish bash library, **not** deployed to the home directory (lives in `scripts/`, which chezmoi already treats as un-managed — see existing siblings `scripts/redact_secrets.py`, `scripts/install_specstory.sh`). Consumed via chezmoi's `{{ include "scripts/lib/sudo_shared.sh" }}` so each `run_*.sh.tmpl` gets the helper text inlined at render time. This avoids shipping a runtime file and keeps the helper authoritative in source form.

Public functions:

| Function | Purpose |
|---|---|
| `sudo_session_init [label]` | Idempotent: if state dir is valid, exports the env vars and returns. Otherwise probes passwordless sudo, else prompts once on `/dev/tty`, validates via `sudo -S -v`, writes the two 0600 files, spawns keep-alive daemon. Registers `trap sudo_session_abort INT TERM HUP`. |
| `sudo_session_skip_reason` | Returns non-empty string ("noRoot"/"non-interactive"/"passwordless") when the caller can bypass sudo entirely, empty otherwise. |
| `sudo_run <cmd...>` | Convenience wrapper: `sudo -S -p '' -- <cmd>` with password piped from `$CHEZMOI_SUDO_PASS_FILE`. For bootstrap's apt lines. |

Exported env vars after `sudo_session_init` succeeds:

- `CHEZMOI_SUDO_STATE_DIR` — e.g. `${XDG_RUNTIME_DIR:-/tmp}/chezmoi-sudo-$UID` (0700)
- `CHEZMOI_SUDO_PASS_FILE` — `$STATE_DIR/sudo.pass` (0600), contains raw password + trailing newline, consumed via `sudo -S < "$file"` pattern
- `CHEZMOI_ANSIBLE_BECOME_FILE` — `$STATE_DIR/ansible-become.yml` (0600), contains only `ansible_become_password: "<escaped>"`, consumed via `ansible-playbook -e @file`
- `CHEZMOI_SUDO_KEEPALIVE_PID` — PID of detached refresher loop

### 3.2 State model & lifetime

State dir layout:
```
$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/     # 0700
├── sudo.pass                            # 0600, raw password
├── ansible-become.yml                   # 0600, ansible_become_password YAML
├── keepalive.pid                        # detached daemon PID
└── chezmoi.pid                          # ancestor chezmoi PID to watch
```

Lifetime rules:

- **Normal script EXIT**: state is preserved (next script in the flow needs it). This intentionally deviates from the literal "trap EXIT cleans up" instruction — per-script EXIT cleanup is incompatible with cross-script sharing. Effective end-of-flow cleanup is delegated to the keep-alive daemon (below).
- **Abort signals (INT/TERM/HUP)**: helper's trap kills the daemon and wipes state — user Ctrl+C'ing mid-flow must not leave the secret on disk.
- **End of flow**: the keep-alive daemon itself is responsible. It `setsid`-detaches from the originating script, watches the recorded chezmoi ancestor PID, and when that PID disappears (or when `sudo -n true` starts failing twice in a row) it `rm -rf`s `$CHEZMOI_SUDO_STATE_DIR` and exits. This is the "prompt once AND self-clean at flow end" trick that per-script EXIT traps can't deliver.
- **`$XDG_RUNTIME_DIR` fallback**: if unset (non-systemd login), state dir goes in `$(mktemp -d -t chezmoi-sudo.XXXXXX)` with 0700.

### 3.3 Upfront detection

Helper exposes `sudo_flow_will_need_sudo` which consults chezmoi-rendered flags. To keep the decision at template-render time (so we can prompt eagerly at bootstrap start), each `run_*.sh.tmpl` sets a `NEED_SUDO` boolean via chezmoi template conditions before sourcing the helper:

```
{{- $needsSudo := false -}}
{{- if eq .chezmoi.os "linux" -}}
  {{- if not .noRoot -}}{{- $needsSudo = true -}}{{- end -}}
{{- else if eq .chezmoi.os "darwin" -}}
  {{- if or .installBrewApps .installInputMethod -}}{{- $needsSudo = true -}}{{- end -}}
{{- end -}}
NEED_SUDO={{ if $needsSudo }}1{{ else }}0{{ end }}
```

(macOS-side `.installInputMethod` is already present in `.chezmoi.toml.tmpl`; `.installBrewApps` likewise.) If `NEED_SUDO=0`, the script skips `sudo_session_init` entirely — no prompt, no state dir.

### 3.4 Keep-alive daemon

Spawned by `sudo_session_init` using `setsid bash -c '…' </dev/null >/dev/null 2>&1 &`. Body roughly:

```bash
CHEZMOI_PID=$1
STATE_DIR=$2
while kill -0 "$CHEZMOI_PID" 2>/dev/null; do
    sudo -S -v < "$STATE_DIR/sudo.pass" 2>/dev/null || break
    sleep 50
done
rm -rf "$STATE_DIR"
```

Ancestor PID discovery: walk `$PPID` via `/proc/$pid/status` (Linux) or `ps -o ppid= -p $pid` (macOS) until a process whose command name matches `chezmoi` is found; fall back to `$PPID` if not found (degrades to "daemon dies with the shell that started it", acceptable).

## Files to change

### New files

- **`scripts/lib/sudo_shared.sh`** — the helper. ~120 lines of bash, with `# WHY:` comments on the non-obvious bits (setsid detach, PID-based lifetime, `/dev/tty` vs stdin choice, `sudo -S` vs `-e @file` split).

### Modified files

- **`run_once_before_00_bootstrap.sh.tmpl`**
  - Around L98 (before the `sudo apt-get update` block at L117): add `{{ include "scripts/lib/sudo_shared.sh" }}`, compute `NEED_SUDO`, call `sudo_session_init "bootstrap"` if `NEED_SUDO=1`.
  - Replace `sudo apt-get update` / `sudo apt-get install -y …` at L117, L118, L159 with `sudo_run apt-get …` so the already-cached password is piped in and no mid-script prompt can occur.
  - Register `trap sudo_session_abort INT TERM HUP` (no EXIT trap — state must survive for the next script).

- **`run_onchange_after_20_ansible_roles.sh.tmpl`**
  - Replace the existing L230–247 prompt-once block with: `{{ include "scripts/lib/sudo_shared.sh" }}` + `sudo_session_init "ansible"`, then `BECOME_FLAGS="-e @$CHEZMOI_ANSIBLE_BECOME_FILE"`.
  - Remove the `sudo -k` at L230 (it was the reason bootstrap's cache got thrown out).
  - Keep the existing non-interactive fallback path (L248–258) but trigger it from `sudo_session_skip_reason` returning `"non-interactive"`.
  - macOS path (L184–191) similarly delegated to the helper.

- **`run_onchange_after_30_brew_bundle.sh.tmpl`**
  - Replace the `sudo -v` block at L79–86 with `{{ include "scripts/lib/sudo_shared.sh" }}` + `sudo_session_init "brew"`. The helper already keeps the timestamp warm (daemon refreshes every 50 s, well inside sudo's 5-minute default), so cask pkg installers that shell out to `sudo /usr/sbin/installer` will find a live cache.

- **`CLAUDE.md`** — add a short "Sudo session sharing" subsection under an existing section (probably right after "Auto-run Scripts") pointing at `scripts/lib/sudo_shared.sh`, explaining:
  - the hybrid file + keep-alive model
  - what files live in `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/`
  - that downstream scripts should source the helper via `{{ include }}` and call `sudo_session_init` rather than rolling their own prompt
  - how cleanup works (daemon tied to chezmoi PID + INT/TERM abort traps)

No changes required in `dot_ansible/ansible.cfg` (`become_ask_pass = False` stays — ansible never prompts, only consumes the vars file). No changes to any role.

## Assumptions & trade-offs forced by repo structure

1. **Helper lives in `scripts/` and is inlined via `{{ include }}`** rather than deployed to `~/.local/bin/` or similar. Reason: each `run_*.sh.tmpl` is rendered to a temp path by chezmoi and executed there; at runtime the script has no reliable path back to the source tree, so sourcing a deployed file would require extra indirection. `include` gives one source of truth with zero runtime-path hazard.

2. **`trap … EXIT` is deliberately NOT registered** (the user's brief listed EXIT alongside INT/TERM/HUP). Reason: each run-script is a separate shell process; a normal EXIT trap in bootstrap fires before ansible starts, defeating reuse. The keep-alive daemon watching the chezmoi PID provides the semantically equivalent "clean up when the flow ends" guarantee. Signal traps (INT/TERM/HUP) remain.

3. **The password sits as plaintext in a 0600 file under `$XDG_RUNTIME_DIR`**. `$XDG_RUNTIME_DIR` is typically `/run/user/$UID` (tmpfs, wiped on logout); if unset, we fall back to a `mktemp -d` under `/tmp`. No in-memory-only option here because bash can't share FDs across unrelated processes, and ansible needs a file path for `-e @file` regardless.

4. **Ancestor PID discovery uses `/proc` on Linux, `ps` on macOS**. Both are standard. If the walk fails to find a `chezmoi` process (e.g. script is being hand-tested without chezmoi), the daemon falls back to tracking `$PPID`, which dies with the invoking shell — safe degradation.

5. **`sudo_run` wrapper hides the password via `sudo -S < file`**, never via command args. `ps` never sees it.

## Verification

End-to-end smoke on Linux (`ubuntu_desktop` or `ubuntu_server`, with passworded sudo):

1. `sudo -k` to clear any cached timestamp.
2. `chezmoi apply --force --verbose` and confirm:
   - exactly one `[sudo] password for $USER:` prompt appears, early in the bootstrap phase;
   - `sudo apt-get install …` in bootstrap proceeds without a second prompt;
   - ansible runs to completion without a prompt;
   - brew-bundle (if enabled) runs without a prompt;
   - after apply finishes, `$XDG_RUNTIME_DIR/chezmoi-sudo-$UID/` is gone (daemon self-cleaned);
   - `pgrep -af 'kill -0' | grep chezmoi-sudo` returns empty (no stray daemon).
3. Abort test: during an apply, hit Ctrl+C during ansible. Verify state dir is wiped immediately and no daemon lingers (`pgrep -af chezmoi-sudo`).
4. Non-interactive test: `chezmoi apply </dev/null 2>&1 | tee log.txt`. Verify we fall through to the existing "run ansible manually" warning path (no hang, exit 0 for apply).
5. `noRoot=true` test: re-`chezmoi init --force` answering yes to `noRoot`, then `chezmoi apply`. Verify no prompt at all and `NEED_SUDO=0` in the rendered bootstrap script.
6. macOS test (if possible): `chezmoi apply` with `installBrewApps=true`. Verify single prompt, cask pkg installers succeed, state wiped after apply.
7. `just bats` still green (tests aren't touching sudo but running them catches accidental shell-syntax regressions in the helper if we add any bats unit tests — optional: add one exercising `sudo_flow_will_need_sudo` pure branches).

Shell linting:

- `shellcheck scripts/lib/sudo_shared.sh` clean (pre-commit will enforce this automatically per the repo's existing rule that `scripts/*.sh` is in scope).
- `shfmt -d scripts/lib/sudo_shared.sh` no diff.
