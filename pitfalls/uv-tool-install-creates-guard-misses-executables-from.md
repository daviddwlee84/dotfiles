# Ansible `creates:` guard makes `uv tool install --with-executables-from` silently no-op on existing installs

**Symptoms** (grep this section):

- After a `chezmoi apply` that updated
  `dot_ansible/roles/python_uv_tools/defaults/main.yml` to add
  `with_executables_from:` for an entry, the listed entry-point packages
  did NOT produce shims in `~/.local/bin`:
  ```
  $ jupyter
  zsh: command not found: jupyter
  $ which jupyter-lab
  /home/daviddwlee84/.local/bin/jupyter-lab     ← primary binary present
  $ ls ~/.local/bin/jupyter*                     ← jupyter / jupyter-notebook missing
  /home/daviddwlee84/.local/bin/jupyter-lab
  ```
- Ansible log shows the install task as `ok` (skipped), not `changed`:
  ```
  TASK [python_uv_tools : Install Python CLI tools via uv]
  ok: [localhost] => (item=jupyterlab)        ← skipped — not what you want
  ✦ changed: [localhost] => (item=marimo[recommended,mcp])
  ```
- Manually running `uv tool install jupyterlab --with ... --with-executables-from notebook --with-executables-from jupyter-core` (without `--force`) produces:
  ```
  Installed 3 executables from `jupyter-core`: jupyter, jupyter-migrate, jupyter-troubleshoot
  Installed 1 executable from `notebook`: jupyter-notebook
  error: Executables already exist: jlpm, jupyter-lab, jupyter-labextension, jupyter-labhub (use `--force` to overwrite)
  ```

## Root cause

The role's install task used:

```yaml
- name: Install Python CLI tools via uv
  ansible.builtin.command: uv tool install {{ item.name }} ...
  args:
    creates: "{{ ansible_facts['env']['HOME'] }}/.local/bin/{{ item.binary }}"
  loop: "{{ python_uv_tools }}"
```

Ansible's `creates:` short-circuits the command if the path exists. For
`jupyterlab`, `binary: jupyter-lab` already existed from a prior apply
(predating the `with_executables_from:` addition), so ansible reported
`ok` and **never executed the install command** — meaning the new
`--with-executables-from notebook jupyter-core` flags never ran, and
`jupyter` / `jupyter-notebook` were never written.

`creates:` is a single-path test; it has no concept of "this entry now
demands additional executables". Same problem applies to anything else
where a defaults change adds new bin shims to an already-installed
`uv tool` entry.

The error from the manual `--reinstall` (without `--force`) is also
informative: uv writes the extras-from shims first, THEN errors on the
primary entry-point conflict and rolls nothing back — so a partial
install is possible. `--force` is required for the resync.

## Fix (in this repo)

Two-part change in `dot_ansible/roles/python_uv_tools/`:

1. **`defaults/main.yml`**: declare `extra_binaries:` alongside
   `with_executables_from:` listing the bin names that must exist for
   the install to be considered complete:

   ```yaml
   - name: jupyterlab
     binary: jupyter-lab
     with_executables_from:
       - notebook
       - jupyter-core
     extra_binaries:
       - jupyter           # from jupyter-core
       - jupyter-notebook  # from notebook
   ```

2. **`tasks/main.yml`**: add a stat-probe pre-task and replace the
   `creates:` guard with a `when:` that fires `--force` when any
   `extra_binaries` entry is missing:

   ```yaml
   - name: Probe extra_binaries presence (for entries using with_executables_from)
     ansible.builtin.stat:
       path: "{{ ansible_facts['env']['HOME'] }}/.local/bin/{{ item.1 }}"
     loop: "{{ python_uv_tools | subelements('extra_binaries', skip_missing=True) }}"
     register: _uv_extra_binaries_probe
     changed_when: false

   - name: Install Python CLI tools via uv
     ansible.builtin.command: >-
       uv tool install
       {% if _force_reinstall %}--force {% endif %}
       {{ item.name }} ...
     vars:
       _missing_extras: >-
         {{ _uv_extra_binaries_probe.results | default([])
            | selectattr('item.0.name', 'equalto', item.name)
            | rejectattr('stat.exists')
            | map(attribute='item.1') | list }}
       _force_reinstall: "{{ _missing_extras | length > 0 }}"
       _primary_exists: "{{ (ansible_facts['env']['HOME'] ~ '/.local/bin/' ~ item.binary) is exists }}"
     when:
       - not (item.needs_modern_gcc | default(false) and gcc_too_old)
       - (not _primary_exists) or _force_reinstall
     loop: "{{ python_uv_tools }}"
   ```

   `--force` is mandatory because re-running without it errors out at
   the primary entry-point step (see Symptoms above).

## Manual one-shot fix on an already-broken host

If you just need the shims back without re-running ansible:

```bash
uv tool install --force 'jupyterlab' \
  --with 'marimo[sandbox]' --with 'marimo-jupyter-extension' \
  --with 'ipykernel' --with 'ipywidgets' \
  --with-executables-from 'notebook' \
  --with-executables-from 'jupyter-core'
```

(Quote `marimo[sandbox]` etc. under zsh — bare brackets are glob
syntax. Bash users don't need the quotes.)

## How to detect this class of drift in future

When a `python_uv_tools` entry has `with_executables_from:` set, the
defaults file MUST also set `extra_binaries:` listing the actual bin
shim names. If a future contributor adds a new entry-point package
without updating `extra_binaries`, the new shim will be silently
missing on every host that already has the primary binary.

Cheap repo-wide audit:

```bash
# Any entry with with_executables_from but no extra_binaries — bug.
yq '.python_uv_tools[] | select(.with_executables_from) | select(.extra_binaries == null) | .name' \
  dot_ansible/roles/python_uv_tools/defaults/main.yml
```

(should print nothing)

## Related pitfalls

- `pitfalls/uv-self-update-homebrew-noop.md` — neighbouring uv-bootstrap trap.
- `pitfalls/ansible-when-regex-replace-backslash-strip.md` — same role, different footgun in the version probe.

## References

- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — `extra_binaries:` field documentation
- `dot_ansible/roles/python_uv_tools/tasks/main.yml` — probe + force-reinstall logic
- `docs/tools/notebooks.md` → "The `jupyter` meta-CLI vs standalone binaries"
- uv `--with-executables-from` PR: <https://github.com/astral-sh/uv/pull/14014> (released uv 0.8.5)
