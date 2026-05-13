# `neovim` role silently no-ops on sudo-having CentOS 7 / Rocky / Alma

## Symptom

Running `chezmoi apply` (or `just ansible-tags neovim`) on a CentOS 7 box
with **working sudo** completes cleanly:

```
PLAY RECAP
localhost : ok=8 changed=0 unreachable=0 failed=0 skipped=23 rescued=0 ignored=0
```

— but `command -v nvim` returns nothing. Eight tasks ran, twenty-three were
skipped, **zero changed**. The 8 that ran were:

1. Pre-task: detect userland architecture
2. Pre-task: set `target_architecture`
3. Pre-task: detect `oldEL`
4. neovim: check current version  (`rc=1`, no nvim)
5. neovim: set `nvim_current_version` (`0.0.0`)
6. neovim: display "required >= 0.11.2"
7. neovim: set `nvim_sys_arch` (`x86_64`)
8. neovim: warn about unsupported arch (skipped — arch is supported)

The user-level fallback block ("Install Neovim tarball (user-level, no sudo
required)") that should have downloaded and extracted nvim — **never fires**.

Different from [`pitfalls/centos7-noroot.md`](centos7-noroot.md): that one
covers `noRoot=true` Debian-only gates on `base` / `starship` / etc. This
one fires when sudo IS available — exactly the path noRoot doesn't exercise.

## Root cause

The `user-level fallback` task in
`dot_ansible/roles/neovim/tasks/main.yml` was gated:

```yaml
- name: Install Neovim tarball (user-level, no sudo required)
  when:
    - ansible_facts["os_family"] in ["Debian", "RedHat"]
    - nvim_current_version is version(neovim_min_version, '<')
    - apt_neovim is not defined  # sudo tasks were skipped
    - nvim_sys_arch | default('') != ''
```

The comment claimed:

> User-level fallback fires when:
>   - Debian noRoot box: `apt_neovim` is undefined (sudo tasks were skipped).
>   - RedHat-family (any noRoot or sudo): no apt branch ran at all, so
>     `apt_neovim` is also undefined.

The first half is correct. **The second half is wrong**, and the wrong
mental model survived testing because the Docker test profile is `centos7`
*with* `noRoot=true` (`docker-test-centos7`) — which dodges this exact
path. The sister test profile that exercises sudo CentOS 7 doesn't exist
yet (see [`backlog/centos7-sudo-test-profile.md`](../backlog/centos7-sudo-test-profile.md)).

### What ansible actually does to `register:` under `when: false`

When an ansible task's `when:` evaluates **False**, the task is "skipped".
**But `register:` is still set** — to a small dict describing the skip:

```yaml
apt_neovim:
  changed: false
  skipped: true
  skip_reason: "Conditional result was False"
```

So `apt_neovim is defined` is **True** on every RedHat box where the
Debian-gated apt task was scheduled-but-skipped. `apt_neovim is not defined`
is correspondingly **False**, and the user-level fallback is skipped.

The reason this works on a Debian noRoot box is different: with
`--skip-tags sudo`, the apt task is removed from the play *before* `when:`
is evaluated. The task literally never runs, so its registered variable
stays undefined. Same word, two different mechanisms.

`ansible.builtin.set_fact` registered variables don't share this trap —
they only set the variable on success. Only `register:` on a `when:`-gated
task accumulates the skip dict.

## Fix

Test for both "never scheduled" AND "scheduled but skipped":

```yaml
- name: Install Neovim tarball (user-level, no sudo required)
  when:
    - ansible_facts["os_family"] in ["Debian", "RedHat"]
    - nvim_current_version is version(neovim_min_version, '<')
    - (apt_neovim is not defined) or (apt_neovim is skipped)
    - nvim_sys_arch | default('') != ''
```

The `or apt_neovim is skipped` clause covers:

- Debian sudo path where apt **succeeded** with an old version → `apt_neovim`
  is defined, not skipped, `changed: true` — user-level skipped (correct,
  the snap or system-level GitHub branches handled the upgrade).
- Debian sudo path where apt failed (`ignore_errors: true`) → user-level
  skipped — wrong but predates this pitfall, separate bug.
- Debian noRoot box → `apt_neovim is not defined` (task removed by
  `--skip-tags sudo`) → user-level fires ✓.
- **RedHat any sudo state** → `apt_neovim is skipped` (task scheduled but
  `when` evaluated False) → user-level fires ✓.
- macOS → `os_family == "Darwin"` already gates the whole block out via
  the outer `Debian/RedHat` predicate.

### Companion fix on CentOS 7 specifically (glibc 2.17)

Even after the gate is fixed, the user-level fallback downloads from
`https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz`,
which since around nvim 0.10 has been built against glibc 2.28+. On CentOS 7
(glibc 2.17) the extracted binary aborts:

```
nvim: /lib64/libc.so.6: version `GLIBC_2.28' not found (required by nvim)
nvim: /lib64/libc.so.6: version `GLIBC_2.33' not found (required by nvim)
nvim: /lib64/libc.so.6: version `GLIBC_2.32' not found (required by nvim)
nvim: /lib64/libm.so.6: version `GLIBC_2.29' not found (required by nvim)
```

Upstream maintains [`neovim/neovim-releases`](https://github.com/neovim/neovim-releases)
specifically for "(unsupported) builds for older glibc" — same version
numbers, rebuilt against an older toolchain. The role now branches on the
`oldEL` fact set in `dot_ansible/playbooks/linux.yml`:

```yaml
- name: Get latest neovim-releases tag (oldEL → glibc 2.17 build)
  when: oldEL | default(false)
  ansible.builtin.uri:
    url: https://api.github.com/repos/neovim/neovim-releases/releases/latest
  register: nvim_oldel_release

- name: Set Neovim tarball URL (oldEL → neovim-releases; else → stable)
  ansible.builtin.set_fact:
    nvim_tarball_url: >-
      {% if oldEL | default(false) -%}
      https://github.com/neovim/neovim-releases/releases/download/{{ nvim_oldel_release.json.tag_name }}/nvim-linux-{{ nvim_tarball_arch }}.tar.gz
      {%- else -%}
      https://github.com/neovim/neovim/releases/download/stable/nvim-linux-{{ nvim_tarball_arch }}.tar.gz
      {%- endif %}
```

`neovim-releases` has no `stable` floating tag — only semver tags like
`v0.12.2` — so we hit the GitHub API to discover the latest. Add ~1 round
trip on oldEL; non-oldEL is unchanged.

## Audit for sibling roles

Any role with the same `register: <name>` + `when: os_family == "Debian"`
+ `<name> is not defined` shape has the same bug latent. To find them:

```bash
rg -nC2 'register:\s+(\w+)' dot_ansible/roles/ | rg -B2 'is not defined'
```

The audit at the time this pitfall landed found one match: the now-fixed
neovim role. Sibling `base` / `starship` / `security_tools` /
`rust_cargo_tools` use a different pattern — `<name>_check.rc != 0`
where the recheck task itself is broadened to `["Debian", "RedHat"]`,
so the variable is genuinely set on both families.

## Why the original Docker test missed it

`docker-test-centos7` runs with `noRoot=true`, which adds `--skip-tags sudo`
to the ansible invocation. That:

1. Strips every task tagged `[sudo]` (including the Debian apt task) from
   the play before `when:` evaluation.
2. So `apt_neovim` is genuinely undefined on the noRoot test path.
3. The user-level fallback fires, nvim installs, the test passes.

A sudo-having CentOS 7 box exercises the *complementary* path — apt task
present, `when` evaluates False — and that's the path nobody had Docker
coverage for. Filed as `backlog/centos7-sudo-test-profile.md` (TBD).

## Related

- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — sister pitfall for
  the `noRoot=true` path. Same broadening idea, different mechanism.
- [`pitfalls/centos7-ansible-yum-dnf-backend.md`](centos7-ansible-yum-dnf-backend.md)
  — what happens when you try to add yum tasks to the sudo path on CentOS 7.
- [`pitfalls/centos7-idc-slow-broken-installs.md`](centos7-idc-slow-broken-installs.md)
  — broader EL7 install survey; mentions glibc-2.17 binary failures.
- `dot_ansible/roles/neovim/tasks/main.yml` — fixed gate.
- `dot_ansible/playbooks/linux.yml` — `oldEL` fact source of truth.
- `dot_ansible/roles/devtools/tasks/main.yml` — the wider centos7-noroot
  gate-broadening sweep landing in the same commit (btop, bat, yazi,
  zellij, lnav, gh, glab, diffnav, superfile, dasel, yq, witr, git-graph,
  tldr, jnv, git-delta-x86_64-musl-switch).
