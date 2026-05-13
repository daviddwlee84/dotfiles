# `just ansible-tags` doesn't auto-detect uv-managed Python on CentOS 7

**Status**: P2
**Effort**: S
**Related**: `TODO.md` (existing line 58 entry on the chezmoi-side pin) · `justfile` `ansible-tags` recipe · `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` (canonical detection logic) · `pitfalls/centos7-noroot.md`

## Context

Surfaced 2026-05-13 trying to install `nvim` + `btop` on a sudo-having
CentOS 7 box via the existing recipe:

```bash
just ansible-tags neovim
```

Failed with:

```
[ERROR]: Task failed: Module result deserialization failed: No start of json char found See stdout/stderr for the returned output.
module_stderr: |4-
      File "/home/yczhang/.ansible/tmp/ansible-tmp-.../AnsiballZ_setup.py", line 3
        from __future__ import annotations
        ^
    SyntaxError: future feature annotations is not defined
```

CentOS 7 ships `/usr/bin/python3` = **Python 3.6.8**. ansible-core 2.18+
modules use `from __future__ import annotations` (Py3.7+ syntax) and
ansible's auto-discovery picks up `/usr/bin/python3` via
`interpreter_python = auto_silent` in `dot_ansible/ansible.cfg` → every
`Gathering Facts` task aborts.

The fix already exists for the **`chezmoi apply`** path:
`run_onchange_after_20_ansible_roles.sh.tmpl` (lines 143-174) probes
`/usr/bin/python3 < 3.7` and falls back to a uv-managed Python 3.13
(found via `~/.local/share/uv/python/cpython-3.13.*-linux-*/bin/python3`
or `uv python find 3.13`), then prepends
`--extra-vars "ansible_python_interpreter=$ANSIBLE_PY_INTERP"` to
`ansible-playbook`.

**The `just ansible-tags` recipe doesn't do any of this.** It's a 1-line
recipe in `justfile`:

```just
ansible-tags tags:
    cd ~/.ansible && ansible-playbook playbooks/$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/').yml --tags "{{tags}}"
```

So agents / users iterating on a single role via `just ansible-tags`
hit the wall on every CentOS 7 box, even though the chezmoi-spawned
ansible run on the same machine works fine.

Workaround discovered today:

```bash
ansible-playbook playbooks/linux.yml --tags neovim \
  --extra-vars "ansible_python_interpreter=$HOME/.local/share/uv/python/cpython-3.13.13-linux-x86_64-gnu/bin/python3"
```

— but the version-pinned path is fragile across machines and across
`uv python install` runs.

## Investigation

Existing canonical detection logic
(`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`):

```bash
ANSIBLE_PY_INTERP=""
detect_target_python() {
    local sys_py="${1:-/usr/bin/python3}"
    if ! [[ -x "$sys_py" ]]; then return 1; fi
    local sys_ver
    sys_ver="$("$sys_py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)" || return 1
    awk -v v="$sys_ver" 'BEGIN { split(v, a, "."); exit !(a[1]>3 || (a[1]==3 && a[2]>=7)) }'
}
if ! detect_target_python; then
    UV_PY_CANDIDATE=""
    for cand in "$HOME"/.local/share/uv/python/cpython-3.13.*-linux-*/bin/python3 \
                "$HOME"/.local/share/uv/python/cpython-3.12.*-linux-*/bin/python3 \
                "$HOME"/.local/share/uv/python/cpython-3.11.*-linux-*/bin/python3 \
                "$HOME"/.local/share/uv/python/cpython-3.10.*-linux-*/bin/python3; do
        [[ -x "$cand" ]] && { UV_PY_CANDIDATE="$cand"; break; }
    done
    [[ -z "$UV_PY_CANDIDATE" ]] && command -v uv &> /dev/null && UV_PY_CANDIDATE="$(uv python find 3.13 ... )"
    [[ -n "$UV_PY_CANDIDATE" && -x "$UV_PY_CANDIDATE" ]] && ANSIBLE_PY_INTERP="$UV_PY_CANDIDATE"
fi
```

This needs to live in **a place that the just recipe can source**.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. Convert `ansible-tags` to a `#!/usr/bin/env bash` recipe** with the same fallback inlined | Zero new files; just script grows ~25 lines | Duplicates the canonical logic; need to keep both in sync (a maintenance trap) |
| **B. Extract `detect_target_python` + `find_uv_python` into `scripts/lib/ansible_interpreter.sh`** and source from both | Single source of truth; `just ansible-tags`, `just ansible-base`, `just ansible-linux`, `just ansible-macos`, `just ansible-check`, `just ansible-security` all benefit | New helper file; `scripts/` is `chezmoi`-ignored (good), but justfile lives at repo root so the source path is stable |
| **C. Wrap `ansible-playbook` in a `scripts/ansible-playbook-wrapper.sh`** that always does the detection + delegate | Centralises across all callers (justfile + manual usage + future scripts) | Implicit indirection; users running `ansible-playbook` directly still hit the bug; doesn't help fleet-broadcast users |
| **D. Symlink `~/.local/bin/python3` → uv-managed 3.13 on CentOS 7 hosts** in the `base` ansible role | Truly fixes the root cause for everyone (curl, ansible, etc.) | Risky — overrides system Python in PATH; could break system tools that depend on Py3.6 specifics; explicit "don't touch system Python" is a sane default |

B is the closest match to existing conventions in this repo
(`scripts/lib/sudo_shared.sh` is the precedent for shared shell helpers
sourced by multiple call sites).

## Current blocker / open questions

- Should this also export `ANSIBLE_PYTHON_INTERPRETER` (env var, ansible
  reads it) instead of `--extra-vars`? Env var is honored by every ansible
  invocation in the same shell, including ad-hoc `ansible -m ping`. The
  existing run-script uses `--extra-vars`; if we extract a shared helper
  it could do both.
- Is the right precedent to put helpers in `scripts/lib/` (sourced by
  shell scripts) or `scripts/` (top-level utilities)? `sudo_shared.sh`
  is in `scripts/lib/`, so B should match.
- The `ansible-syntax-check` recipe doesn't need this fallback (syntax
  check doesn't gather facts). Skip it from the wrapper.

## Decision (if any)

Likely **B** when next blocked. Until then, the workaround at the top of
this doc is documented in `pitfalls/centos7-noroot.md` (controller-side
"Python pin" section).

## References

- `pitfalls/centos7-noroot.md` → "CentOS 7 also ships Python 3.6.8" section
- `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl:140-175` (canonical detection)
- `justfile:218-219` (the bare `ansible-tags` recipe)
- `dot_ansible/ansible.cfg:8` (`interpreter_python = auto_silent`)
- 2026-05-13 manual repro on `idc-server104` (CentOS 7.9, glibc 2.17, sudo, uv-managed Python 3.13.13 already installed at `~/.local/share/uv/python/cpython-3.13.13-linux-x86_64-gnu/`).
