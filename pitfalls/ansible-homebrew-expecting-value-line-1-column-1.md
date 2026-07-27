# `Module failed: Expecting value: line 1 column 1 (char 0)` from `community.general.homebrew`

**Symptoms** (grep this section): `[ERROR]: Task failed: Module failed: Expecting value: line 1 column 1 (char 0)` at a `community.general.homebrew` / `homebrew_cask` task (seen at `roles/devtools` "Install resvg via Linuxbrew when available (Debian/RedHat)") / `fatal: [localhost]: FAILED! (0.6s)` with `changed: false` and no other detail / `PLAY RECAP ... failed=1` / `chezmoi: .chezmoiscripts/global/20_ansible_roles.sh: exit status 2` / `chezmoi apply` aborts before `25_bat_theme` / `30_brew_bundle` / `45_yazi_plugins` / `50_generate_completions` ever run. Also: `brew bundle` reporting success while installing nothing; `uv`/`herdr` upgrades silently no-op'ing.
**First seen**: 2026-07-27, CentOS 7.9 host `idc-server104` (`profile=centos_server`, `installBrewApps=false`), during `chezmoi update --apply --init`
**Affects**: any host where a **fake `brew` stub** sits on `PATH` — the standard hack for stopping bootstrap from installing Linuxbrew on a distro Homebrew doesn't support
**Status**: fixed — glibc gate in bootstrap (no stub needed anymore) + all brew probes now test output instead of exit status

## Symptom

```
[65] TASK · [devtools : Install resvg via Linuxbrew when available (Debian/RedHat)]
[ERROR]: Task failed: Module failed: Expecting value: line 1 column 1 (char 0)
Origin: /home/yczhang/.ansible/roles/devtools/tasks/main.yml:2444:3

✘ fatal: [localhost]: FAILED! (0.6s) =>
    changed: false
    msg: 'Task failed: Module failed: Expecting value: line 1 column 1 (char 0)'
```

The message is a **Python `json.loads` error leaking through the module**, not
an ansible error — so it names neither `brew` nor the formula. `failed=1`
aborts the play, and because `20_ansible_roles.sh` then exits 2, every later
`run_after_` script is skipped: no bat theme, no brew bundle, no yazi plugins,
no completion regeneration. The visible damage is far away from the cause.

## Root cause

`~/.local/bin/brew` was a 17-byte fake:

```sh
#!/bin/sh
exit 0
```

It exists because bootstrap's Linuxbrew step was gated only on `noRoot` and
`command -v brew`, so on a distro where Homebrew can't work the only way to
stop it re-attempting the install on every bootstrap re-run was to satisfy
`command -v brew`. (The repo already knew this platform was hopeless — see the
`-x` guard comment in `run_once_before_00_bootstrap.sh.tmpl`: *"a failed
Homebrew installer (e.g. CentOS 7 where curl < 7.41 aborts mid-install) leaves
/home/linuxbrew/.linuxbrew/ as an empty sudo'd skeleton"*.)

The stub is a **universal liar**:

| Probe | Real brew | Stub | Verdict |
|---|---|---|---|
| `command -v brew` | path, rc 0 | path, rc 0 | ✗ fooled |
| `which brew` | path, rc 0 | path, rc 0 | ✗ fooled |
| `brew list --formula uv` | rc 0/1 | **rc 0**, no output | ✗ fooled |
| `brew info --json=v2 <f>` | JSON | **empty**, rc 0 | ✗ fooled |
| `brew --prefix` | `/home/linuxbrew/.linuxbrew` | **empty**, rc 0 | ✓ catches it |

`exit 0` means *every* subcommand succeeds and prints nothing. So the probe
task reported "brew available", the `when:` guard passed, and
`community.general.homebrew` ran `brew info --json=v2 resvg`, got `""`, and
died inside `json.loads("")`.

**The general lesson: a stub can fake an exit status but not output.** Probe
external tools by what they *print*, not by whether they *ran*.

## Fix

Two halves, both needed — otherwise removing the stub just makes bootstrap try
to install Linuxbrew again.

**1. Give bootstrap a real reason to skip Linuxbrew** — a glibc floor in
`run_once_before_00_bootstrap.sh.tmpl`:

```bash
BREW_GLIBC_VER="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+([0-9.]*)?$' || true)"
awk -v v="$BREW_GLIBC_VER" 'BEGIN { split(v,a,"."); exit !((a[1]>2)||(a[1]==2&&a[2]>=28)) }'
```

2.28 is the RHEL 8 / Debian 10 floor: it excludes CentOS/RHEL 7 (glibc 2.17)
while leaving Ubuntu 20.04 (2.31) and newer on the normal path. Homebrew
advertises glibc >= 2.13, but modern bottles are built against far newer, so
below the floor `brew install` degrades to compiling everything from source.
The skip is a separate branch, **not** folded into the architecture `case` —
that one's `*)` arm does `rm -rf /home/linuxbrew/.linuxbrew`, which must not
fire just because glibc is old.

**2. Probe by output everywhere.** The canonical forms now used repo-wide:

```yaml
# ansible, stdout-as-boolean (devtools ×8)
ansible.builtin.shell: '[ -n "$(brew --prefix 2>/dev/null)" ] && command -v brew || true'

# ansible, rc-as-boolean (coding_agents ×3, llm_tools ×1)
ansible.builtin.shell: '[ -n "$(brew --prefix 2>/dev/null)" ]'
args:
  executable: /bin/bash
```

```bash
# shell scripts (scripts/upgrade_tools.sh defines this once and reuses it)
brew_usable() { [[ -n "$(brew --prefix 2>/dev/null)" ]]; }
```

Then delete the stub: `rm ~/.local/bin/brew`.

## Why it took a while to find

- The error names no tool. `Expecting value: line 1 column 1 (char 0)` is
  generic `json.loads` failure; grepping it finds Stack Overflow posts about
  reading empty files, not Homebrew.
- `brew` resolving to `~/.local/bin/brew` instead of
  `/home/linuxbrew/.linuxbrew/bin/brew` looks unremarkable in `which` output.
- Bootstrap prints `[INFO] Linuxbrew is already installed` — actively
  reassuring, and wrong.
- The failing task is `failed_when`-less in a role full of best-effort
  `|| true` probes, so it reads as if it should have been non-fatal.

## Related

- [`homebrew-aliyun-brew-git-hang-core-clone-bloat.md`](homebrew-aliyun-brew-git-hang-core-clone-bloat.md) — other brew-on-a-mirror traps
- [`homebrew-6-refuses-untrusted-tap-formula.md`](homebrew-6-refuses-untrusted-tap-formula.md)
- [`apt-update-fails-base-role-empty-error.md`](apt-update-fails-base-role-empty-error.md) — same shape: one ansible task with an empty/opaque error aborting the whole play and skipping every later `run_after_` script
