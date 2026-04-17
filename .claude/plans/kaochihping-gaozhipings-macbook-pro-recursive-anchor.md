# Fix LiteLLM install failure on fresh macOS (Python 3.14 / orjson build)

## Context

On a freshly-provisioned M5 Mac, `ansible llm_tools : Install LiteLLM via uv` failed. The failure is not a chezmoi/ansible bug — it's a transitive build failure:

- `uv` on the new machine picked Python **3.14** for the ephemeral tool venv (no other Python present; uv 0.11.7 defaults to the newest managed CPython).
- `litellm[proxy]==1.83.9` pins `orjson==3.10.15`.
- `orjson 3.10.15` does **not** publish a cp314 macOS arm64 wheel, so `uv` falls back to building from source.
- The sdist's bundled `pyo3-ffi 0.23.3` hard-refuses Python > 3.13: `error: the configured Python interpreter version (3.14) is newer than PyO3's maximum supported version (3.13)`.
- The build also bootstraps rustup (because no Rust present), which wastes ~11 minutes before the compile error surfaces.

On the reporter's original machine this worked because uv had Python 3.13 cached from the pre-existing `python_uv_tools` install (which pins `thefuck` to 3.11 but otherwise accepts 3.13). On the new M5 Mac, bootstrap order caused `litellm` to be the *first* tool touched while 3.14 was the selected interpreter.

The companion role `python_uv_tools` already supports a per-tool `python:` override (see `dot_ansible/roles/python_uv_tools/defaults/main.yml:11` pinning thefuck to 3.11). `llm_tools` lacks this support, so today there is no way to pin litellm's interpreter.

Goal: pin litellm's build interpreter to a version orjson 3.10.15 ships wheels for (3.13), by adding `--python` support to the `llm_tools` role and pinning litellm to `3.13`. This avoids the source build entirely.

## Change

Two tiny edits, scoped to the `llm_tools` role:

1. `dot_ansible/roles/llm_tools/tasks/main.yml` — extend the `uv tool install` command to pass `--python {{ item.python }}` when `item.python` is defined. Mirror the exact template fragment already used in `dot_ansible/roles/python_uv_tools/tasks/main.yml:8`.

2. `dot_ansible/roles/llm_tools/defaults/main.yml` — add `python: "3.13"` to the `litellm[proxy]` entry.

No changes to other roles, playbooks, profiles, README, or CLAUDE.md are required (the `python:` field is a role-internal detail, same as in `python_uv_tools`).

## Files to modify

- `dot_ansible/roles/llm_tools/tasks/main.yml` (task at line 15)
- `dot_ansible/roles/llm_tools/defaults/main.yml` (entry at line 8)

## Reuse

Copy the Jinja `{% if item.python is defined %}--python {{ item.python }} {% endif %}` fragment verbatim from `dot_ansible/roles/python_uv_tools/tasks/main.yml:8` so the two roles stay consistent.

## Verification

On the failing M5 Mac (or any fresh macOS) after pulling the fix:

1. `chezmoi update` (or `chezmoi apply` if already pulled).
2. Re-run just the failing role:
   ```bash
   cd ~/.ansible && ansible-playbook playbooks/macos.yml --tags llm_tools
   ```
3. Expected: `uv tool install litellm[proxy] --python 3.13 --with httpx[socks]` downloads a prebuilt `orjson-3.10.15-cp313-*-macosx_11_0_arm64.whl` (no Rust/rustup, no maturin build).
4. Confirm binary: `~/.local/bin/litellm --version` and `uv tool list | grep litellm` should show it on 3.13.
5. Syntax check locally:
   ```bash
   ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
   ```

## Notes / non-goals

- Not widening the fix to "pass `PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1`" — that would still trigger a full Rust toolchain download on fresh machines (slow, brittle).
- Not bumping litellm to a newer release that may ship orjson ≥ 3.10.18 (has cp314 wheels) — that's a larger change and still leaves other orjson-pinning tools exposed; pinning the interpreter is the targeted fix.
- Not adding retries to the `llm_tools` task in this change (the `python_uv_tools` role has retries; we can align later, but it's unrelated to this failure).
