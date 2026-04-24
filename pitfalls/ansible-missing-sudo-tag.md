# `chezmoi apply` in noRoot mode fails with `sudo: a password is required` at an ansible task (missing `tags: [sudo]`)

**Symptoms** (grep this section):
- On a host provisioned with `noRoot=true`, `chezmoi apply` runs the ansible
  phase, reports most tasks `ok`, then fails abruptly at ONE task with:
  ```
  [ERROR]: Task failed: Premature end of stream waiting for become success.
  >>> Standard Error
  sudo: a password is required
  Origin: /home/<user>/.ansible/roles/<role>/tasks/main.yml:<N>:3
  ```
- `run_onchange_after_20_ansible_roles.sh: exit status 2` → whole `chezmoi apply`
  aborts, downstream `run_*` scripts never execute
- The same task runs cleanly on rooted dev boxes, so CI/testing doesn't catch it
- Exactly reproducible: `ssh HOST chezmoi apply` fails at the same task on every
  invocation until the ansible YAML is patched

**First seen**: 2026-04 on `jingle-207` (Ubuntu 22.04, `ubuntu_server` profile,
`noRoot=true`), task `devtools : Ensure xz is available for worktrunk extraction (Debian/Ubuntu)`
at `dot_ansible/roles/devtools/tasks/main.yml:2415`
**Affects**: any ansible task in this repo that has `become: true` but NO
`tags: [sudo]`, executed on a host where `noRoot=true` was chosen at
`chezmoi init`
**Status**: workaround = add the missing tag. Structural prevention = repo
convention (see [Prevention](#prevention)).

## Symptom

Full failing output from the noRoot host:

```
[71] TASK · [devtools : Ensure xz is available for worktrunk extraction (Debian/Ubuntu)]
[ERROR]: Task failed: Premature end of stream waiting for become success.
>>> Standard Error
sudo: a password is required
Origin: /home/ldw/.ansible/roles/devtools/tasks/main.yml:2415:3

2413     PATH: "{{ ansible_facts['env']['HOME'] }}/.local/bin:/usr/local/bin:{{ ansible_facts['env']['PATH'] }}"
2414
2415 - name: Ensure xz is available for worktrunk extraction (Debian/Ubuntu)
       ^ column 3

✘ fatal: [localhost]: FAILED! (0.5s) =>
    changed: false
    msg: |-
        Task failed: Premature end of stream waiting for become success.
        >>> Standard Error
        sudo: a password is required
```

```
localhost                  : ok=70   changed=4    unreachable=0    failed=1    skipped=199  rescued=0    ignored=0
chezmoi: 20_ansible_roles.sh: exit status 2
```

The offending YAML at the time (missing the tag):

```yaml
- name: Ensure xz is available for worktrunk extraction (Debian/Ubuntu)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
  ansible.builtin.apt:
    name: xz-utils
    state: present
  become: true
  failed_when: false      # ← `failed_when: false` doesn't help here
  # ← missing: tags: [sudo]
```

## Root cause

noRoot mode in this repo is NOT implemented as an ansible variable (e.g.
`no_root: true` with `when: not no_root`). It is implemented at the **shell
wrapper** layer, in `run_onchange_after_20_ansible_roles.sh.tmpl:249` (approx):

```bash
{{ if $noRoot -}}
info "noRoot mode enabled - installing user-level tools to ~/.local/bin"
...
BECOME_FLAGS="--skip-tags sudo"
{{- end }}
```

Which becomes, at invocation time:

```bash
ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --tags "$TAGS" --skip-tags sudo …
```

The mechanism is `ansible-playbook --skip-tags sudo` — so any task that wants
to be skipped on noRoot hosts MUST declare `tags: [sudo]`. A task with
`become: true` but without the tag will:

1. Bypass the `--skip-tags sudo` filter (no matching tag to skip)
2. Hit the `become: true` escalation path
3. Ansible's become plugin (`sudo` by default) tries to acquire root
4. The sudoers config on noRoot hosts doesn't grant passwordless sudo to the
   user → `sudo` emits `a password is required` on stderr and exits non-zero
5. Ansible interprets this as "Premature end of stream waiting for become
   success" → task fails → play aborts

Why `failed_when: false` doesn't save you: `failed_when: false` evaluates the
**module result**. The failure above happens in the **become handshake**,
before the module ever runs. Ansible treats become failures as fatal
regardless of `failed_when` / `ignore_errors`.

Why tagging works: a `--skip-tags sudo` match is evaluated during task
scheduling, before become is attempted. The task is dropped from the play
entirely, the sudoers prompt never happens.

## Workaround

Add the tag to the offending task. Canonical pattern (from
`dot_ansible/roles/devtools/tasks/main.yml:3115`, which gets this right):

```yaml
- name: Ensure xz-utils is available for jnv tarball extraction
  when:
    - ansible_facts["os_family"] == "Debian"
    - jnv_recheck.rc != 0
  become: true
  tags: [sudo]             # ← required for noRoot hosts
  ansible.builtin.apt:
    name: xz-utils
    state: present
  failed_when: false
```

Note the ordering: `become: true` / `tags: [sudo]` / module declaration is the
style used across this repo. Match it for consistency.

If the skipped task means a downstream user-level install path also can't
succeed (e.g. the xz apt skip means a `.tar.xz` unarchive downstream will
fail), add a **probe + gate** so the downstream block doesn't waste bandwidth
and time:

```yaml
- name: Probe for xz binary (worktrunk extraction dependency)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
  ansible.builtin.shell: command -v xz || true
  args: { executable: /bin/bash }
  register: worktrunk_xz_probe
  changed_when: false

- name: Install worktrunk from GitHub releases (Debian/Ubuntu, user-level)
  when:
    - ansible_facts["os_family"] == "Debian"
    - worktrunk_check.rc != 0
    - target_architecture in ['x86_64', 'amd64', 'aarch64', 'arm64']
    - worktrunk_xz_probe.stdout | default('') | trim != ''   # ← skip when xz absent
  block:
    ...
```

## Prevention

**Repo convention**: any ansible task in `dot_ansible/roles/**` that uses
`become: true` MUST also declare `tags: [sudo]`. No exceptions — even for
tasks you're "sure" won't run on noRoot hosts, because the profile
combinations drift over time.

**Manual audit** before merging a PR that adds or edits become-using tasks:

```bash
# Find `become: true` lines that are NOT followed within ~5 lines by tags: [sudo]
# (crude — manually review the hits)
cd /home/ldw/.local/share/chezmoi
rg -n -B 0 -A 5 '^\s*become:\s*true' dot_ansible/ | less
```

Or more targeted, if ripgrep supports multiline (it does with `--multiline`):

```bash
rg --multiline --multiline-dotall -U \
   'become:\s*true(?![^\n]*\n\s*tags:\s*\[sudo\]|[^\n]*\n[^\n]*\n\s*tags:\s*\[sudo\])' \
   dot_ansible/
```

Expect false positives around handlers (`become:` in a handler doesn't need
`tags:` if the handler is only notified from tagged tasks) — eyeball the
matches, don't auto-fix.

**Local test for noRoot mode** (before committing the ansible change):

```bash
# Simulate noRoot by running ansible directly with --skip-tags sudo
cd /home/ldw/.local/share/chezmoi/dot_ansible
ansible-playbook -i localhost, -c local setup.yml.tmpl \
  --tags devtools --skip-tags sudo --check
```

The `--check` flag is crucial — in normal mode it would try to actually run
apt, which is what you're trying to prove is skipped.

## Related

- [CLAUDE.md § Sudo session is shared across all run-scripts](../CLAUDE.md) —
  describes the full sudo-helper flow that noRoot mode short-circuits
- [`pitfalls/npm-postinstall-github-releases-hang.md`](npm-postinstall-github-releases-hang.md)
  — sibling "this only breaks on one host profile" pitfall, different root
  cause (network vs sudoers)
- `dot_ansible/roles/devtools/tasks/main.yml:3115` — reference pattern (jnv
  xz-utils task, gets it right)
- `run_onchange_after_20_ansible_roles.sh.tmpl:249` — where
  `BECOME_FLAGS="--skip-tags sudo"` is set for noRoot runs
