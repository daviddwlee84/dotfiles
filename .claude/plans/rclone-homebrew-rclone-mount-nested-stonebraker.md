# Fix Homebrew-6 tap-trust breakage + document rclone-mount/macFUSE reality on macOS

## Context

A `chezmoi update` on the Mac mini (macOS 26.2, Homebrew 6.0.2) failed the
`devtools` ansible role with:

```
Error: Refusing to load formula raine/workmux/workmux from untrusted tap raine/workmux.
Run `brew trust --formula raine/workmux/workmux` or `brew trust raine/workmux` to trust it.
```

**Homebrew 6.0 added a formula-trust security gate**: `brew install` now refuses
to load formulae from third-party taps until the tap is explicitly trusted. The
repo taps two third-party formulae in `devtools` — `raine/workmux` and
`dlvhdr/formulae` (diffnav) — and **both are currently `Untrusted`** (verified
via `brew tap-info`). The install task died on `workmux`; the next run would die
on `diffnav`. This blocks `chezmoi apply` entirely. **This is the must-fix.**

Separately, the user asked to review the rclone install method under the belief
"Homebrew rclone doesn't support mount." Investigation showed that premise is
**now outdated**:

- `/opt/homebrew/bin/rclone mount --help` works (rc=0) — modern Homebrew rclone
  (≥1.73) is built with `cmount`/macFUSE support. **Brew rclone supports mount on macOS today.**
- The machine has **3 rclone binaries**: `~/.local/bin/rclone` v1.74.3 (official,
  wins on PATH), `/opt/homebrew/bin/rclone` v1.73.0 (brew), `/usr/local/bin/rclone`
  v1.70.3 (stray root-owned manual install).
- The **real** blocker for `rclone mount` on macOS 26 is **macFUSE**: installed
  version is **4.10.2** (from 2025-08-01) but macOS 26.2 rejects it → the
  "Unsupported macOS Version" dialog. The cask now ships **5.2.0**. macFUSE is
  **not managed by this repo** at all.
- Linux rclone already installs the **official build** to `~/.local/bin`
  (`devtools/tasks/main.yml:1943-2022`) which supports mount via libfuse — no change needed.

**Decisions (confirmed with user):** keep brew rclone on macOS (no install-method
change — document the finding); document the macFUSE manual-upgrade path rather
than managing it in ansible (it needs a reboot + GUI security approval, which
violates the install-only philosophy); fix the tap-trust failure.

## Changes

### 1. Fix the Homebrew-6 untrusted-tap failure (blocking) — `dot_ansible/roles/devtools/tasks/main.yml`

Insert a trust step **between** the two `homebrew_tap` tasks (lines 9–23) and the
`Install developer CLI tools (macOS)` task (line 25). `community.general.homebrew_tap`
has no trust parameter (feature is brand-new), so use `ansible.builtin.command`.

Idempotent + back-compatible (older Homebrew has no trust concept, so `tap-info`
won't contain `Untrusted` and the trust task no-ops — no need to version-gate):

```yaml
- name: Check trust state of third-party taps (macOS, Homebrew >= 6.0 formula-trust gate)
  when: ansible_facts["os_family"] == "Darwin"
  ansible.builtin.command: "brew tap-info {{ item }}"
  loop:
    - dlvhdr/formulae
    - raine/workmux
  register: devtools_tap_info
  changed_when: false
  failed_when: false

- name: Trust untrusted third-party taps (macOS)
  when:
    - ansible_facts["os_family"] == "Darwin"
    - "'Untrusted' in item.stdout"
  ansible.builtin.command: "brew trust {{ item.item }}"
  loop: "{{ devtools_tap_info.results }}"
  loop_control:
    label: "{{ item.item }}"
  changed_when: true
```

Notes:
- Trust **both** taps — `dlvhdr/formulae` is also `Untrusted` and would fail on
  the next run otherwise.
- Keep this driven off the existing tap list; if a future third-party tap is
  added to this role, add it to the `loop` here too (call this out in the
  inline comment).
- This touches the `devtools` role which is surface #1 of the workmux status-icon
  6-file invariant in CLAUDE.md, but that invariant is about the `🤖`/`💬`/`✅`
  status mechanism — adding a tap-trust step does not affect it. No mirror update needed.

### 2. Document macFUSE as the real macOS mount prerequisite (the user-chosen "document only" path)

**a. New pitfall** `pitfalls/macfuse-too-old-unsupported-macos-version-rclone-mount.md`
(title by symptom per the project-knowledge-harness convention). Capture:
- Symptom: macFUSE GUI dialog **"Unsupported macOS Version — The installed version
  of macFUSE is too old for the operating system."** appearing on `rclone mount`
  / boot after a macOS major upgrade (here macOS 26.2 with macFUSE 4.10.2).
- Root cause: macFUSE kernel/system extension is version-locked to the macOS major;
  4.x is not loadable on macOS 26 — needs 5.x.
- Non-obvious bit: `brew info --cask macfuse` reports the **new** version (5.2.0)
  while `/opt/homebrew/Caskroom/macfuse/<old>` is what's actually installed; the
  cask is `auto_updates` so `brew upgrade` won't bump it and a kernel-extension
  reinstall + reboot + GUI approval is required.
- Fix: `brew reinstall --cask macfuse` → reboot → System Settings ▸ Privacy &
  Security ▸ allow the "Benjamin Fleischer" system extension → reboot again if prompted.
- Note that rclone itself (brew or official build) is *not* the problem — both
  support mount; macFUSE is the runtime dependency.

**b. New pitfall** `pitfalls/homebrew-6-refuses-untrusted-tap-formula.md`. Capture
the exact error string `Refusing to load formula <tap>/<formula> from untrusted tap`,
that it is a Homebrew 6.0 change, that it silently blocks the whole `chezmoi apply`
ansible run, and the repo fix (the trust task above) plus the manual one-liner
`brew trust <tap>`.

**c. `pitfalls/README.md`** — add both new entries to the index (follow existing
symptom-first row format).

**d. `docs/infra/shared-storage.md`** — under the existing `### rclone (S3 / WebDAV
/ GDrive as POSIX)` section (around line 182), add a short **macOS prerequisite**
note: `rclone mount` on macOS requires a current macFUSE (5.x on macOS 26+);
brew rclone supports mount, the binary choice is not the blocker; link the macFUSE pitfall.

**e. `docs/this_repo/tool-managers.md`** — the rclone A–Z row (line 1037) and the
install-mechanism table (line 302): add a brief parenthetical that macOS `rclone
mount` additionally needs **macFUSE (manual, not managed — see pitfall)**, and
note brew rclone now ships with mount support so the install method is unchanged.
Optionally add a one-line note about the Homebrew-6 tap-trust step for third-party taps.

### Not doing (out of scope per user decisions)
- Not adding the pasted `rclone-install` just recipe (brew rclone already mounts).
- Not switching macOS rclone to the official build.
- Not managing macFUSE via ansible.
- Redundant-binary cleanup (`/usr/local/bin/rclone` root-owned stray, the extra
  `~/.local/bin/rclone`) is a user-env tidiness item, **mentioned in the doc/pitfall
  as optional**, not a repo change.

## Verification

1. **Syntax/lint**: `just lint` (or `ansible-lint dot_ansible/roles/devtools/tasks/main.yml`)
   if available; at minimum `python3 -c "import yaml,sys; yaml.safe_load(open('dot_ansible/roles/devtools/tasks/main.yml'))"`.
2. **Trust idempotency, dry run**: `brew tap-info raine/workmux` / `brew tap-info
   dlvhdr/formulae` should show `Untrusted` *before*; after `brew trust raine/workmux`
   they flip to `Trusted` and the trust task reports `ok` (unchanged) on re-run.
3. **End-to-end (the real test)**: re-run the failed step —
   `chezmoi apply` (or narrowest: ansible `devtools` tag) — and confirm the
   `Install developer CLI tools (macOS)` task now succeeds (workmux + diffnav install).
   Per the repo "validate with the app" rule, this re-run is the validation that the fix works.
4. **macFUSE doc accuracy**: confirm `brew info --cask macfuse` shows 5.2.0 vs the
   older Caskroom path, matching what the pitfall describes. `mkdocs build --strict`
   for the touched docs pages.
