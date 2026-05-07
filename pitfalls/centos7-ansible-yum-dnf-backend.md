# `ansible.builtin.yum:` aborts on CentOS 7 — "Could not detect dnf revision"

## Symptom

Running ansible-core 2.18+ (anything you'd `uv tool install` today) against
a CentOS 7 host, every `ansible.builtin.yum:` task fails:

```
[ERROR]: Task failed: Action failed:
  ('Could not detect which major revision of dnf is in use, which is required to determine module backend.',
   'You should manually specify use_backend to tell the module whether to use the dnf4 or dnf5 backend')
Origin: /home/yczhang/.ansible/roles/base/tasks/main.yml:52:3

50 # handles them more reliably (musl tarballs ignore glibc 2.17). Skipped
51 # entirely on noRoot (tags: [sudo] → --skip-tags sudo).
52 - name: Install base packages (RedHat/CentOS)
     ^ column 3

✘ fatal: [localhost]: FAILED! (0.7s) =>
    ansible_facts:
        pkg_mgr: unknown
    msg:
    - Could not detect which major revision of dnf is in use ...
    - You should manually specify use_backend to tell the module whether to use the dnf4 or dnf5 backend
...ignoring
```

`ignore_errors: true` keeps the play going, but **the package never gets
installed** — `git`, `git-lfs`, `jq`, `gcc`, `gawk`, `zsh`, etc. are
silently absent on the target after a "successful" `chezmoi apply`.
Downstream tasks then fail in mysterious ways (e.g. `modify_*.json: jq
not found`, `ble.sh Makefile: gawk not found`).

## Root cause

ansible-core 2.18 collapsed the `yum` module into a thin alias that
routes through the `dnf` module backend
([release notes](https://docs.ansible.com/ansible/latest/porting_guides/porting_guide_2.18.html)).
The module's runtime auto-detection looks for `dnf` / `dnf-3` / `dnf-5`
binaries to decide which backend to invoke. **CentOS 7 ships only
`/usr/bin/yum` — there is no `dnf` binary anywhere on the system**.
Detection returns nothing, the module aborts.

`use_backend: yum` (or `yum3`) used to force the legacy yum-CLI path,
but that fallback was removed in ansible-core 2.18 too. The
parameter still accepts `dnf | dnf4 | dnf5 | auto`, none of which work
without a dnf binary.

This is **independent** from the noRoot CentOS 7 issue documented in
[`centos7-noroot.md`](centos7-noroot.md) (which covers the OS-family
gating around user-level GitHub-release fallbacks). The `dnf-backend`
trap fires when sudo IS available — exactly the path noRoot doesn't
exercise — so the two pitfalls compound: noRoot users dodge this
entirely; sudo'd CentOS 7 users hit it on every system-package task.

## Fix

Replace `ansible.builtin.yum:` with `ansible.builtin.shell:` invoking
yum CLI directly + `rpm -q` for idempotency:

```yaml
- name: Install base packages (RedHat/CentOS) — yum CLI for CentOS 7 + Rocky/Alma compat
  when: ansible_facts["os_family"] == "RedHat"
  become: true
  tags: [sudo]
  # Why `${missing[*]:-}` and not `${#missing[@]}`?  See "Jinja2 trap" below.
  ansible.builtin.shell: |
    set -e
    missing=()
    for p in git git-lfs curl wget jq tree gcc gcc-c++ make; do
      rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ -z "${missing[*]:-}" ]; then
      echo "ALL_INSTALLED"
      exit 0
    fi
    yum install -y "${missing[@]}"
  args:
    executable: /bin/bash
  register: base_yum_result
  changed_when: "'ALL_INSTALLED' not in base_yum_result.stdout"
  ignore_errors: true
```

### Jinja2 trap: `${#array[@]}` reads as a Jinja2 comment block

The natural bash idiom for "is the array empty" is:

```bash
if [ ${#missing[@]} -eq 0 ]; then ...
```

ansible's `shell:` / `command:` modules run their content through Jinja2
templating before handing off to the target. **Jinja2's comment syntax
is `{# ... #}`** — and `${#missing[@]}` contains the literal substring
`{#missing[@]}`, which Jinja2 reads as the start of a comment block. The
parser then scans forward looking for the closing `#}` (which never
arrives) and aborts with:

```
[ERROR]: Error loading tasks: failed at splitting arguments,
  either an unbalanced jinja2 block or quotes: set -e
  pkgs=(...)
  ...
  if [ ${#missing[@]} -eq 0 ]; then
       ^^^^^^^^^^^^^^^^^^^^
```

The error origin points at the **task header line** (`- name: ...`),
not the offending shell line, which makes it look like a YAML
indentation issue. It isn't.

Fixes that all work:

| Form | Notes |
|------|-------|
| `[ -z "${missing[*]:-}" ]` | Cleanest. Expands to space-joined array (empty when unset); `-z` tests empty. |
| `[ "$(echo "${missing[@]+x}")" = "" ]` | Verbose but explicit. |
| `{{ '${#missing[@]}' }}` | Wrap in a Jinja2 raw-string literal. Ugly. |
| `{% raw %}...{% endraw %}` block | Whole-script raw block. Loses any *intentional* var substitution. |

Same trap applies to `${#var}` (string length) anywhere in `shell:` /
`command:` blocks. Either avoid the syntax or use `{% raw %}`.

Why this works on **both** CentOS 7 and Rocky/Alma 8+:

- CentOS 7: `yum` is the real package manager (yum 3.x, Python 2 era).
- Rocky/Alma 8+: `/usr/bin/yum` is a symlink/shim to `dnf` — running
  `yum install` from the shell invokes dnf transparently. No
  feature loss vs. `ansible.builtin.yum:`.

Why `rpm -q` first: `yum install -y X` of an already-installed package
returns success but its output is "Package X already installed" — we use
the explicit `ALL_INSTALLED` sentinel to keep ansible's `changed:`
reporting honest. Saves repeated `yum install` calls (slow on networks
behind GFW where the metadata refresh alone takes minutes).

Applied across `dot_ansible/roles/{base,zsh,bash,ruby_gem_tools}/tasks/main.yml`
in the same commit that opened this pitfall. Future RHEL-family yum
tasks should follow the same pattern.

## Why not...

- **Install dnf on CentOS 7 first**: requires EPEL + `yum install dnf`.
  EPEL works but bootstrapping a new package manager just to satisfy
  ansible's module backend feels backwards, and the result is still
  brittle (dnf on EL7 is upstream-deprecated).
- **`community.general.yum`**: doesn't exist as a separate module —
  yum lives only in ansible-core, and the dnf-backend collapse there is
  the source of the bug.
- **`ansible.builtin.package`**: discovers `pkg_mgr` from facts; on
  CentOS 7 it currently reports `pkg_mgr: unknown` (visible in the
  error above), defeating auto-routing. Same root cause.
- **Pin ansible-core to 2.17 on the controller**: 2.17 still has the
  yum CLI fallback. But it's EOL'd Q4 2025; not a sustainable answer.
  Also conflicts with [`centos7-noroot.md`](centos7-noroot.md)'s fix
  pinning Python 3.13 + ansible-core 2.18+ via `uv tool install` —
  that pin exists because *older* ansible-core versions can't speak
  Galaxy NG.

## Related

- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — sister pitfall:
  user-level GitHub-release / cargo / mise fallbacks gated wrongly on
  `os_family == "Debian"` (sudo-less CentOS 7 path).
- [`pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md`](bootstrap-no-tty-sudo-prompt-skipped.md) —
  upstream dependency: without sudo, ansible doesn't even reach these
  tasks (gets gated by `tags: [sudo]` + `--skip-tags sudo`).
- `dot_ansible/roles/{base,zsh,bash,ruby_gem_tools}/tasks/main.yml` —
  the four tasks that needed the `shell:` rewrite.
- ansible-core 2.18 porting guide:
  <https://docs.ansible.com/ansible/latest/porting_guides/porting_guide_2.18.html>

## Repro (Docker)

```bash
just docker-test-centos7   # full suite — currently expects yum tasks to pass
```

When this pitfall first surfaced (CentOS 7 + sudo + ansible-core 2.20),
none of the existing Docker test profiles caught it because:

- `docker-test-centos7` previously ran with `noRoot=true` (skipped sudo
  tasks entirely)
- `docker-test-rocky9` has dnf installed, so the auto-detection works

Adding a `centos7-sudo` Docker variant would close that gap; tracked in
[`backlog/centos7-sudo-test-profile.md`](../backlog/centos7-sudo-test-profile.md)
once filed.
