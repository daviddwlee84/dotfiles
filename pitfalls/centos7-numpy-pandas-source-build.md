# `uv tool install visidata / sqlit-tui[ssh]` fails on CentOS 7 — "NumPy requires GCC >= 9.3"

## Symptom

`python_uv_tools` ansible role on a CentOS 7 host:

```
TASK [python_uv_tools : Install Python CLI tools via uv]
ok: [localhost] => (item=thefuck)
ok: [localhost] => (item=apprise)
FAILED - RETRYING: Install Python CLI tools via uv (3 retries left).
FAILED - RETRYING: Install Python CLI tools via uv (2 retries left).
FAILED - RETRYING: Install Python CLI tools via uv (1 retries left).
failed: [localhost] (item=sqlit-tui[ssh]) => ...
    stderr: |-
        Resolved 67 packages in 86ms
           Building pandas==2.3.3
           Building pyarrow==21.0.0
           Building duckdb==1.5.2
          × Failed to download and build `pandas==2.3.3`
          ├─▶ Failed to install requirements from `build-system.requires`
          ├─▶ Failed to build `numpy==2.4.4`
          ╰─▶ Call to `mesonpy.build_wheel` failed (exit status: 1)
              ../meson.build:25:4: ERROR: Problem encountered: NumPy requires GCC >= 9.3
              C compiler for the host machine: cc (gcc 4.8.5 "cc (GCC) 4.8.5 20150623 (Red Hat 4.8.5-44)")
ok: [localhost] => (item=tmuxp)
failed: [localhost] (item=visidata) => ... [same numpy meson failure]
ok: [localhost] => (item=copyparty)
ok: [localhost] => (item=trafilatura)
```

`thefuck`, `apprise`, `tmuxp`, `copyparty`, `trafilatura` install fine
(pure-Python). The two failing items both transitively require numpy
2.x:

| Item | C-build chain |
|------|---------------|
| `sqlit-tui[ssh]` | `textual-fastdatatable` → `pandas` → `numpy 2.x` (needs gcc 9.3+) |
| `visidata` | explicit `--with pandas pyarrow` → `pandas` → `numpy 2.x` |
| `mlflow` | `sqlalchemy` → `greenlet` (C++ ext; CentOS 7 gcc 4.8.5 supports C++11 only with explicit `-std=c++11`, which greenlet's setup.py doesn't pass) |

## Root cause

Two compounding issues:

1. **numpy 2.x dropped manylinux_2_17 wheels.** numpy 1.x shipped wheels
   for the manylinux_2_17 baseline (CentOS 7's glibc 2.17 era), so old
   hosts could `pip install numpy` and get a binary. numpy 2.x bumped
   the baseline to manylinux_2_28 (glibc 2.28 = RHEL 8 / Ubuntu 20.04).
   On a CentOS 7 host targeting **Python 3.13** (which is what `uv tool
   install` lands on by default once the controller is on uv-managed
   3.13), no compatible wheel exists → uv falls back to source build.
2. **numpy 2.x meson build asserts GCC ≥ 9.3.** numpy 2's source build
   uses meson + Cython 3 + heavy AVX2/AVX-512 codegen that requires
   recent compiler features. CentOS 7 ships **gcc 4.8.5** (2015), which
   numpy's `meson.build` explicitly rejects:

   ```meson
   if cc.version().version_compare('<9.3')
     error('NumPy requires GCC >= 9.3')
   endif
   ```

The pandas chain is identical because pandas 3.x depends on numpy 2.x.

## Why uv can't fall back to numpy 1.x

uv resolves the dependency graph based on what `pandas`/`textual-
fastdatatable` declares. Modern pandas pins `numpy>=2.0`, so uv has no
freedom to downgrade — the only way to get numpy 1.x is to constrain
**pandas** itself to < 2.0. Doing that would break the upstream tools
that requested modern pandas.

We could pin specific tools to Python 3.11 (where numpy 1.x wheels still
exist for manylinux_2_17), but that requires per-tool special-casing
and defeats `uv tool install`'s automatic Python management.

## Fix in this repo

`dot_ansible/roles/python_uv_tools/`:

1. **`defaults/main.yml`** — add a `needs_modern_gcc: true` flag to
   tools whose dependency chain pulls numpy 2.x source build:
   ```yaml
   - name: sqlit-tui[ssh]
     binary: sqlit
     needs_modern_gcc: true   # textual-fastdatatable -> pandas -> numpy 2.x
     with: [psycopg2-binary, pymysql, mssql-python, pyodbc, duckdb]
   - name: visidata
     binary: vd
     needs_modern_gcc: true   # explicit pandas + pyarrow deps
     with: [pandas, pyarrow]
   ```

2. **`tasks/main.yml`** — probe `gcc -dumpversion`, set
   `gcc_too_old` fact when major < 9, then skip flagged tools:
   ```yaml
   when: not (item.needs_modern_gcc | default(false) and gcc_too_old)
   ```

CentOS 7 (gcc 4.8.5) skips `sqlit-tui[ssh]` and `visidata`; everything
else installs as before. Rocky 9 / Ubuntu 22.04+ have gcc ≥ 11 so
`gcc_too_old=false` and the loop runs unchanged.

## Manual fallback if you really want them

You can install via conda/mamba (which has its own gcc-12 toolchain
prebuilt) into a dedicated env:

```bash
mamba create -n vd python=3.11 visidata pandas pyarrow -y
conda activate vd
vd  # works
```

Or accept Python 3.11 for these tools specifically, since manylinux_2_17
numpy 1.x wheels still exist there:

```bash
uv tool install --python 3.11 visidata --with 'pandas<2' --with pyarrow
```

But these are manual escape hatches — the role's default is "skip on
old GCC" because chasing the wheel/version matrix per-host is fragile.

## Related

- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — sister
  glibc-2.17-on-modern-toolchain story for binary CLIs (musl wheels
  ignore glibc).
- [`pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md`](bootstrap-no-tty-sudo-prompt-skipped.md) —
  same host class, different bootstrap-time symptom.
- [`pitfalls/centos7-ansible-yum-dnf-backend.md`](centos7-ansible-yum-dnf-backend.md) —
  another CentOS 7 ansible-side fix in the same family.
- numpy 2.x release notes:
  <https://numpy.org/doc/stable/release/2.0.0-notes.html#manylinux-baseline>
- pandas 2.x manylinux change:
  <https://github.com/pandas-dev/pandas/issues/55226>
