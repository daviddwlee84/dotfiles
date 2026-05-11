# `regex_replace` in `when:` clause silently mangles backslashes → version test fails with `'<' not supported between str and int`

**Symptoms** (grep this section):

- An ansible `when:` clause uses `regex_replace(...)` and `is version(...)`,
  e.g.:
  ```yaml
  when: >-
    (_uv_ver.stdout | regex_replace('^uv (\S+).*', '\1')) is version('0.8.5', '<')
  ```
- The task fails with:
  ```
  [ERROR]: Task failed: The test plugin 'ansible.builtin.version' failed:
    Version comparison failed:
    '<' not supported between instances of 'str' and 'int'
  ```
- The exact same `regex_replace` call inside `debug.msg: "{{ ... }}"` works
  perfectly and prints the expected substring (e.g. `0.8.5`).
- The error mentions `str` vs `int` even though both versions in your
  comparison look numeric (`0.7.4` vs `0.8.5`) — there are no alpha
  components like `dev` or `rc` to explain it.
- Adding a `debug` task with the **same expression but using
  `\\S` / `\\1` (double-escaped)** makes it work, but the
  single-escaped variant inside `when: >-` keeps failing.
- Reproducible on Ansible core ≥ 2.18 with Python 3.13 (where `distutils`
  is removed and ansible falls back to `looseversion`/`packaging`).

**First seen**: 2026-05 on Hanrus-Mac-mini while gating
`dot_ansible/roles/python_uv_tools` on `uv >= 0.8.5` (the version that
introduced `--with-executables-from`).
**Affects**: any ansible task that pipes `regex_replace` into the
`is version()` test inside a `when:`/`failed_when:`/`changed_when:` clause
written as a YAML folded scalar (`>-`) or a YAML plain scalar.
**Status**: fixed in
`dot_ansible/roles/python_uv_tools/tasks/main.yml` by extracting the
version with `awk '{print $2}'` in the registering shell command and
storing it in a `set_fact` before any `is version()` comparison —
no `regex_replace` in `when:` at all.

## Symptom

```
TASK [python_uv_tools : Fail if uv is too old] *********************************
[ERROR]: Task failed: The test plugin 'ansible.builtin.version' failed:
  Version comparison failed:
  '<' not supported between instances of 'str' and 'int'

Task failed.
Origin: /Users/zhouhanru/.ansible/roles/python_uv_tools/tasks/main.yml:12:3

10   changed_when: false
11
12 - name: Fail if uv is too old
     ^ column 3
…
18   when: >-
           ^ column 9
…
Version comparison failed: '<' not supported between instances of 'str' and 'int'
```

The misleading part is the error wording. `version_compare` says
"comparing str and int", but **both your operands are strings**
(`'0.7.4'` and `'0.8.5'`). The `int` is being introduced by ansible/python
internally when one side parses as a version with mixed alpha/numeric
components — and that only happens because the value being compared was
silently corrupted upstream.

## Root cause: backslashes are stripped one extra time inside `when:`

Ansible parses a `when:` (or `failed_when:` / `changed_when:`) clause
through **two** template layers:

1. The YAML scalar parser (folded `>-`, plain, or quoted).
2. Then a Jinja **conditional** lexer — which is *not* the same path as
   the `{{ … }}` template lexer used in `debug.msg:` and friends.

The conditional lexer normalises one extra layer of backslash escapes
before handing the expression to Jinja. So this clause:

```yaml
when: >-
  (_uv_ver.stdout | regex_replace('^uv (\S+).*', '\1')) is version('0.8.5', '<')
```

becomes effectively:

```python
regex_replace(_uv_ver.stdout, '^uv (S+).*', '1')
```

— the `\S` is now a literal `S`, the `\1` is a literal `1`. The pattern
no longer matches `"uv 0.7.4 (6fbcd09b5 2025-05-15)"` (because there is
no literal `S` after `uv `). Per `regex_replace`'s contract, **a
non-matching pattern returns the input unchanged**:

```
result = "uv 0.7.4 (6fbcd09b5 2025-05-15)"
```

That is what gets passed to `is version('0.8.5', '<')`. The `version`
test then tries to parse `"uv 0.7.4 ..."` as a version, splits it on
whitespace/dots, and ends up comparing the string component `"uv"`
with the integer component `0` from `'0.8.5'` — hence the
`'<' not supported between instances of 'str' and 'int'` message.

The exact same expression inside `debug.msg: "{{ … }}"` does NOT trigger
this because `{{ … }}` template strings only get the YAML pass + the
**template** Jinja lexer (not the conditional one). The backslashes
survive intact and the regex matches.

## Reproducer

```yaml
# /tmp/repro.yml
- hosts: localhost
  gather_facts: false
  tasks:
    - shell: echo "uv 0.7.4 (6fbcd09b5 2025-05-15)"
      register: r
      changed_when: false

    # Works — `{{ }}` keeps the backslashes
    - debug:
        msg: "extracted={{ r.stdout | regex_replace('^uv (\\S+).*', '\\1') }}"
        # → "extracted=0.7.4"

    # Works — same expression, single-escaped, but evaluated as a template
    - debug:
        msg: >-
          extracted2={{ r.stdout | regex_replace('^uv (\S+).*', '\1') }}
        # → "extracted2=0.7.4"

    # FAILS — same expression in a `when:` clause; \S → S, \1 → 1
    - debug:
        msg: "fired"
      when: >-
        (r.stdout | regex_replace('^uv (\S+).*', '\1')) is version('0.8.5', '<')
        # → "Version comparison failed: '<' not supported between str and int"
```

## Workarounds (in preference order)

### 1. **Don't use `regex_replace` in `when:` at all** — extract upstream

Pull the substring out at the registering step (with `awk`/`sed`/`cut`)
and pass a clean value to `set_fact`. The `when:` clause then compares
that fact directly:

```yaml
- name: Probe uv version
  ansible.builtin.shell: uv --version | awk '{print $2}'
  args: { executable: /bin/bash }
  register: _uv_ver
  changed_when: false

- name: Set uv_version fact
  ansible.builtin.set_fact:
    uv_version: "{{ _uv_ver.stdout | trim }}"

- name: Fail if too old
  ansible.builtin.fail:
    msg: "uv {{ uv_version }} < required {{ min_uv_version }}"
  when: uv_version is version(min_uv_version, '<')
```

This is what `dot_ansible/roles/python_uv_tools/tasks/main.yml` now does.

### 2. Double-escape backslashes in `when:`

If you must keep `regex_replace` inline, write `\\S` and `\\1`:

```yaml
when: "(r.stdout | regex_replace('^uv (\\S+).*', '\\1')) is version('0.8.5', '<')"
```

(Note the surrounding **double quotes** + double backslashes — folded
`>-` makes this even harder to reason about, prefer plain double-quoted
scalars when you have to.)

### 3. Use `regex_search`'s capture group syntax

`regex_search('uv (\S+)', '\\1')` returns just the group, no fallback to
the original input on miss — but it'll return `None` on miss, and
`None is version('0.8.5', '<')` raises a different (more obvious)
error, so failures are louder.

## Why the error message is misleading

Ansible's `version` test calls `looseversion.LooseVersion` /
`packaging.version.parse` under the hood. When given
`"uv 0.7.4 (6fbcd09b5 2025-05-15)"`, `LooseVersion` parses each
whitespace/dot-separated component independently into either `int`
(if numeric) or `str`. The `0.8.5` literal is parsed as
`(0, 8, 5)` (all int). The polluted "version" is parsed as
`("uv", 0, 7, 4, "(6fbcd09b5", 2025, 5, 15, ")")` (mixed). The first
component-wise comparison hits `"uv" < 0` → Python raises
`TypeError: '<' not supported between instances of 'str' and 'int'`.

Ansible re-raises that as
`The test plugin 'ansible.builtin.version' failed: Version comparison failed: ...`,
giving zero hint that the *real* problem is the regex didn't match.

## How to verify the regex actually matched

Add a temporary debug right before the `when:` clause, but use
`{{ }}` template form (which works correctly), not the same `when:`
expression form:

```yaml
- debug:
    msg: "extracted='{{ _uv_ver.stdout | regex_replace('^uv (\\S+).*', '\\1') }}'"
```

If `extracted='0.7.4'` you have the correct value; if
`extracted='uv 0.7.4 (...)'` your regex never matched and
`when:`-based comparisons will explode.

## Related

- This repo's
  [`AGENTS.md` → Validate app configs with the app, not just syntax](../AGENTS.md)
  invariant — `ansible-playbook --syntax-check` would NOT have caught
  this. You must actually run the role (or the smallest narrow play)
  to surface it.
- [Ansible issue #41555](https://github.com/ansible/ansible/issues/41555)
  documents the same backslash-stripping pattern in `when:` clauses for
  arbitrary Jinja filters (not just `regex_replace`); the recommended
  fix is identical (extract upstream, compare on a fact).
