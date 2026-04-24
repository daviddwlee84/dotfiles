# `chezmoi apply` on jingle-207 (noRoot=true): two bugs

## Context

On `jingle-207` (Ubuntu 22.04, ubuntu_server profile, **noRoot=true**), `chezmoi apply` fails with two independent issues:

1. **ansible task hits `sudo: a password is required`** at `devtools : Ensure xz is available for worktrunk extraction (Debian/Ubuntu)` even though the machine is in noRoot mode. Root cause: that task is missing the `tags: [sudo]` annotation, so `ansible-playbook --skip-tags sudo` (the mechanism this repo uses to honor noRoot) doesn't skip it. Exit status 2 from `run_onchange_after_20_ansible_roles.sh` aborts the whole `chezmoi apply`.

2. **Neovim `nvim-treesitter` parser builds fail with `EACCES`** on every language. The native tree-sitter binary at `/home/ldw/.local/share/mise/installs/node/24.13.0/lib/node_modules/tree-sitter-cli/tree-sitter` is a **0-byte file with mode `0600`** (neither executable nor has any content). Caused by an earlier `npm install -g tree-sitter-cli` whose postinstall `install.js` download stream silently failed (GitHub release CDN → Azure blob is flaky behind GFW), leaving the empty file behind. Ansible's detection is too weak to notice: `treesitter_check` runs `tree-sitter --version`, which in `cli.js` just reads `package.json` — it exits `0` reporting `0.26.8` without ever touching the broken native binary. So every re-apply happily skips the reinstall.

Both are broad "install path is too optimistic about success / too naive about capability" bugs, so the fix for each is a small guard in the same ansible role.

---

## Bug 1: worktrunk xz task missing `tags: [sudo]` (+ wasted work in noRoot)

### Current state

`dot_ansible/roles/devtools/tasks/main.yml:2415–2423`:

```yaml
- name: Ensure xz is available for worktrunk extraction (Debian/Ubuntu)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
  ansible.builtin.apt:
    name: xz-utils
    state: present
  become: true
  failed_when: false
  # ← missing tags: [sudo]
```

Precedent for the fix already exists in the same file — `dot_ansible/roles/devtools/tasks/main.yml:3115` (`Ensure xz-utils is available for jnv tarball extraction`) does it correctly, and the noRoot plumbing (`BECOME_FLAGS="--skip-tags sudo"`) is in `run_onchange_after_20_ansible_roles.sh.tmpl:249`.

### Downstream consequence in noRoot mode

Even after tagging, the rest of the worktrunk block (lines 2425–2522) will still run and attempt `get_url` + `unarchive` on a `.tar.xz`. If `xz` isn't already on PATH (linuxbrew etc.), extraction fails, the `rescue:` block warns and cleans up. That's correct graceful degradation, but **wastes a ~4MB download + 2 retries on every apply** on every noRoot machine without xz. Worktrunk only publishes `-musl.tar.xz` — no `.tar.gz` alternative — confirmed via live `gh api`.

### Fix

Two-part change to `dot_ansible/roles/devtools/tasks/main.yml`:

**(a) Tag the apt task so `--skip-tags sudo` honors it** (line 2415):

```yaml
- name: Ensure xz is available for worktrunk extraction (Debian/Ubuntu)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
  become: true
  tags: [sudo]          # ← add this
  ansible.builtin.apt:
    name: xz-utils
    state: present
  failed_when: false
```

**(b) Probe for `xz` after the apt task and gate the install block on it** — insert between the apt task and the existing `Install worktrunk from GitHub releases …` block (before line 2425):

```yaml
- name: Probe for xz binary (worktrunk extraction dependency)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
  ansible.builtin.shell: command -v xz || true
  args:
    executable: /bin/bash
  register: worktrunk_xz_probe
  changed_when: false
```

Then extend the `when:` of the install block (currently 2427–2429) with one more condition:

```yaml
- name: Install worktrunk from GitHub releases (Debian/Ubuntu, user-level)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
    - target_architecture in ['x86_64', 'amd64', 'aarch64', 'arm64']
    - worktrunk_xz_probe.stdout | default('') | trim != ''     # ← add this
  block:
    …
```

Result: on noRoot machines without xz, the apt task is skipped (tagged), the probe finds no xz, the block is skipped entirely with no wasted download/retries. On rooted or brew-equipped machines xz is present and the block runs as before. This matches the existing `television` / `taplo` pattern (probe linuxbrew, branch on presence) already in this file.

---

## Bug 2: tree-sitter detection can't see an empty native binary

### Current state

`dot_ansible/roles/lazyvim_deps/tasks/main.yml:229–241`:

```yaml
- name: Check if tree-sitter is installed
  when: ansible_facts["os_family"] == "Debian"
  ansible.builtin.shell: |
    PATH="${HOME}/.cargo/bin:${PATH}" tree-sitter --version
  args: { executable: /bin/bash }
  register: treesitter_check
  changed_when: false
  failed_when: false
```

Verified locally: `tree-sitter --version` returns `tree-sitter 0.26.8` with **rc=0** despite the native binary being 0 bytes. `cli.js` returns the version from `package.json`, never spawning the native binary. So the npm+cargo reinstall paths at lines 251 / 294 are never reached on a broken-empty-binary host.

The 0-byte binary itself comes from an upstream bug in `tree-sitter-cli`'s `install.js`: a failed download leaves an empty destination file, and the process still exits 0. We can't fix that from here — we have to detect it.

### Fix

Strengthen `treesitter_check` to also probe a parse-path code path that requires the native binary. The cheapest proxy: generate a tiny grammar or run `tree-sitter dump-languages` / `tree-sitter parse` — but those are overkill and add dependencies.

Simpler: split the check into two registers. First `--version` (cheap sanity), then — only if `--version` succeeded — a second probe that **verifies the resolved `tree-sitter` binary at the end of symlink chain is a non-empty executable**. Keep `failed_when: false` on both.

New block replacing lines 229–241:

```yaml
- name: Check if tree-sitter --version works
  when: ansible_facts["os_family"] == "Debian"
  ansible.builtin.shell: |
    PATH="${HOME}/.cargo/bin:${PATH}" tree-sitter --version
  args: { executable: /bin/bash }
  register: treesitter_version_check
  changed_when: false
  failed_when: false

- name: Verify tree-sitter native binary is non-empty + executable
  # tree-sitter-cli's postinstall download can fail silently, leaving an
  # empty 0-byte native binary (mode 0600). `--version` still reports OK
  # (it only reads package.json), so the cheap check passes — but every
  # `:TSInstall`/parser build explodes with EACCES on spawn. Re-check
  # the resolved binary to catch this.
  when:
    - ansible_facts["os_family"] == "Debian"
    - treesitter_version_check.rc == 0
  ansible.builtin.shell: |
    set -e
    bin=$(PATH="${HOME}/.cargo/bin:${PATH}" command -v tree-sitter)
    # resolve symlinks (mise shim → mise bin → cli.js; cli.js spawns ./tree-sitter)
    real_cli=$(readlink -f "$bin")
    native="$(dirname "$real_cli")/tree-sitter"
    # cli.js lives next to the native binary in tree-sitter-cli/
    [[ -s "$native" ]] && [[ -x "$native" ]]
  args: { executable: /bin/bash }
  register: treesitter_native_check
  changed_when: false
  failed_when: false

- name: Compute treesitter_check aggregate
  ansible.builtin.set_fact:
    treesitter_check:
      rc: >-
        {{ 0 if (treesitter_version_check.rc | default(1) == 0
                 and treesitter_native_check.rc | default(1) == 0)
           else 1 }}

- name: Purge broken empty tree-sitter native binary (if present)
  when:
    - ansible_facts["os_family"] == "Debian"
    - treesitter_version_check.rc | default(1) == 0
    - treesitter_native_check.rc | default(1) != 0
  ansible.builtin.shell: |
    set -e
    bin=$(PATH="${HOME}/.cargo/bin:${PATH}" command -v tree-sitter)
    real_cli=$(readlink -f "$bin")
    native="$(dirname "$real_cli")/tree-sitter"
    if [[ -e "$native" && ! -s "$native" ]]; then
      rm -f "$native"
      echo "removed empty tree-sitter native binary: $native"
    fi
  args: { executable: /bin/bash }
  changed_when: "'removed' in (treesitter_native_purge.stdout | default(''))"
  register: treesitter_native_purge
```

Downstream tasks already gate on `treesitter_check.rc != 0` (lines 246, 267, 284, 300) — no edits needed to the npm/cargo install paths. After the fact construction above, those gates resolve correctly.

### Immediate manual recovery (not part of plan file — user runs these outside plan mode)

```bash
rm -f ~/.local/share/mise/installs/node/24.13.0/lib/node_modules/tree-sitter-cli/tree-sitter
mise exec -- npm install -g tree-sitter-cli
# if that fails (e.g. postinstall download still blocked), fall back:
cargo install tree-sitter-cli
```

Then in Neovim: `:TSInstall! all` (or just let it retry on open).

---

## Critical files to modify

| File | Lines | Change |
|------|-------|--------|
| `dot_ansible/roles/devtools/tasks/main.yml` | 2415 | add `become: true` + `tags: [sudo]` (reorder, match jnv precedent at 3115) |
| `dot_ansible/roles/devtools/tasks/main.yml` | after 2423, before 2425 | add xz probe task |
| `dot_ansible/roles/devtools/tasks/main.yml` | 2427–2429 | add `worktrunk_xz_probe.stdout…` condition |
| `dot_ansible/roles/lazyvim_deps/tasks/main.yml` | 229–241 | replace single check with version + native-binary + aggregate + purge |
| `pitfalls/ansible-missing-sudo-tag.md` | new | see below |
| `pitfalls/tree-sitter-cli-empty-native-binary.md` | new | see below |

No doc updates required under `docs/` or `README.md` — pure ansible-internal guards, not a user-facing surface change.

No CLAUDE.md update required — bug fix, not a cross-file invariant. (If either pitfall later recurs on other hosts or silently corrupts state, CLAUDE.md's pitfalls-graduation rule says promote to a Hard invariant; not yet.)

### New pitfalls (symptom-titled, verbatim errors, per CLAUDE.md pitfalls rules)

**`pitfalls/ansible-missing-sudo-tag.md`** — title: _"`chezmoi apply` in noRoot mode fails at `Ensure xz is available for worktrunk extraction` with `sudo: a password is required`"_

Body outline:
- Verbatim error: `Task failed: Premature end of stream waiting for become success. / sudo: a password is required` at `roles/devtools/tasks/main.yml:2415`.
- Why: noRoot mode is implemented as `ansible-playbook --skip-tags sudo` (not an ansible var). Any task with `become: true` must ALSO declare `tags: [sudo]` or it escapes the skip filter and the sudoers prompt hard-fails a non-interactive run.
- How it hides: works fine on rooted dev boxes (the machines the author usually tests on), breaks only on server profile + noRoot.
- Non-obvious workaround / convention: grep precedent — `jnv` xz task at `roles/devtools/tasks/main.yml:3115–3124` is the canonical pattern. Any new `become: true` in an ansible role in this repo MUST be paired with `tags: [sudo]`.
- Detection for future audits: `rg -U 'become: true(?![^-]*tags: \[sudo\])' dot_ansible/` (crude, will have false positives around handlers — still a useful sanity pass).

**`pitfalls/tree-sitter-cli-empty-native-binary.md`** — title: _"nvim-treesitter `:TSInstall` fails on every language with `spawn …/tree-sitter-cli/tree-sitter EACCES` even though `tree-sitter --version` reports a version"_

Body outline:
- Verbatim error (multi-line, include the Node.js stack so future-me grep-finds it):
  ```
  Error: spawn /home/…/mise/installs/node/…/lib/node_modules/tree-sitter-cli/tree-sitter EACCES
      errno: -13, code: 'EACCES',
      syscall: 'spawn …/tree-sitter-cli/tree-sitter',
      spawnargs: [ 'build', '-o', 'parser.so' ]
  ```
- Why: tree-sitter-cli's npm `postinstall` (`install.js`) downloads a prebuilt Linux binary from GitHub release-assets (Azure blob CDN). Behind GFW / on flaky network the gunzip stream fails silently, leaving a **0-byte file with mode `0600`** next to `cli.js`, and the process still exits 0. `tree-sitter --version` returns fine because cli.js reads `package.json` without ever touching the native binary — so ansible's version probe sees a healthy install and skips the reinstall. Every `:TSInstall` / `:TSUpdate` then explodes because each parser build does `spawn('./tree-sitter', ['build', …])`.
- Non-obvious fix: detect via `[[ -s $native && -x $native ]]` not `--version`.
- Recovery recipe: `rm` the empty binary, then `mise exec -- npm install -g tree-sitter-cli` (or `cargo install tree-sitter-cli` if the CDN is still unreachable — TUNA mirror for crates works behind GFW).
- Symptom that misleads: `tree-sitter 0.26.8` printed correctly → easy to rule out "tree-sitter not installed" and chase nvim config instead. Spent real time here.

---

## Verification

After applying the ansible changes on jingle-207 (or any noRoot Ubuntu host):

1. **Worktrunk xz path**:
   ```bash
   chezmoi apply  # should now pass through the worktrunk section
   ```
   Expect in the output:
   - `Ensure xz is available for worktrunk extraction` → `skipped` (tag filter)
   - `Probe for xz binary (worktrunk extraction dependency)` → `ok`
   - `Install worktrunk from GitHub releases …` → `skipped` (xz probe empty)
   - `wt` absent from `~/.local/bin` — acceptable in noRoot mode.

   On a host that DOES have xz (linuxbrew, docker/CI, rooted box), the install block runs and `wt --version` works after.

2. **Tree-sitter detection**:
   On the current broken jingle-207, after manual recovery above, re-run:
   ```bash
   chezmoi apply
   ```
   Then intentionally break it again to exercise the new guard:
   ```bash
   : > ~/.local/share/mise/installs/node/24.13.0/lib/node_modules/tree-sitter-cli/tree-sitter
   chmod 600 ~/.local/share/mise/installs/node/24.13.0/lib/node_modules/tree-sitter-cli/tree-sitter
   chezmoi apply
   ```
   Expect:
   - `Check if tree-sitter --version works` → `ok` (rc 0)
   - `Verify tree-sitter native binary is non-empty + executable` → `ok` but `rc != 0`
   - `Purge broken empty tree-sitter native binary` → `changed`
   - `Install tree-sitter-cli via mise npm` → `changed` (reinstall fires)
   - After apply, `nvim +'TSInstall! bash' +qa` completes with no EACCES spam.

3. **No regression on healthy hosts**: on any host where tree-sitter already works (not 0-bytes), the version check is `ok rc 0`, the native check is `ok rc 0`, aggregate `rc = 0`, reinstall is skipped. Same observable behavior as today.
