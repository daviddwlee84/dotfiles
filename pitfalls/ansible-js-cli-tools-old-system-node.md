# `js_cli_tools` ansible role fails with `EBADENGINE` / `EACCES` on old system Node.js

**Symptoms** (grep this section):
- `just fleet-apply-one <host>` shows: `[1;33m[WARN][0m Tag 'js_cli_tools' had failures (continuing in best-effort mode)`
- Same error appears for `coding_agents` tag (it also calls `npm install --global` for `@openai/codex`, `@githubnext/github-copilot-cli`, etc.)
- ansible task `[js_cli_tools : Install missing js_cli_tools via npm]` retries 3 times, then fails:
  ```
  npm WARN EBADENGINE Unsupported engine {
  npm WARN EBADENGINE   package: 'readability-cli@4.1.1',
  npm WARN EBADENGINE   required: { node: '>=14' },
  npm WARN EBADENGINE   current: { node: 'v12.22.9', npm: '8.5.1' }
  npm WARN EBADENGINE }
  npm ERR! code EACCES
  npm ERR! syscall mkdir
  npm ERR! path /usr/local/lib/node_modules/readability-cli
  npm ERR! errno -13
  ```
- Two failure modes stacked: (a) Node version too old for the package's `engines` field, (b) `EACCES` because npm tries to write to `/usr/local/lib/node_modules` as a non-root user
- `apt-cache policy nodejs` shows the only candidate is the Ubuntu jammy `12.22.9~dfsg-1ubuntu3.6` from `universe`
- Most other ansible tags pass cleanly — only `js_cli_tools` and `coding_agents` (which both call `npm install --global` against system npm) fail

**First seen**: 2026-04-24 on `ts_nas` (Ubuntu 22.04 jammy, no NodeSource repo, mise installed but no node version registered)
**Affects**: any host where `/usr/bin/npm` exists (because Ubuntu's `apt install npm` pulled it in) AND the system Node is older than the engine requirement of any package in the `js_cli_tools` / `coding_agents` lists. Currently the strictest is `@openai/codex` (Node ≥18); most others are Node ≥14.
**Status**: no workaround in role yet — see "Fix paths" below; the `js_cli_tools` role detects npm presence but **not version**, so it picks the system v8.5.1 instead of falling through to mise.

## Why

`dot_ansible/roles/js_cli_tools/tasks/main.yml:1-12` boils down to:

```yaml
- name: Detect whether npm is on PATH
  ansible.builtin.command: npm --version
  register: js_cli_npm_check
  failed_when: false

- name: Locate user-installed mise (js_cli_tools fallback)
  when: js_cli_npm_check.rc != 0   # ← only falls back when npm is *missing*
  ...
```

`ts_nas` has `npm` on PATH (Ubuntu's apt-installed v8.5.1 / Node v12.22.9), so the role takes the "use system npm" branch. But:

1. **Engine mismatch**: modern packages (`@openai/codex` requires Node ≥18, `readability-cli` requires Node ≥14) reject install with `EBADENGINE`.
2. **Permission mismatch**: system npm's global prefix is `/usr/local`, which is root-owned; `--global` install as user fails with `EACCES`.

The same problem hits `coding_agents` because it shares the same npm-detection helper for `@openai/codex` and `@githubnext/github-copilot-cli`.

## Fix paths (none implemented yet)

Pick whichever fits the host's intent:

### A. Bump the role to enforce a minimum Node version

Patch `js_cli_tools` (and mirror in `coding_agents`) to compare `js_cli_npm_check.stdout` against a minimum (e.g. `v18`) and fall through to mise when the system npm is too old:

```yaml
- name: Detect whether npm is on PATH
  ansible.builtin.command: node --version
  register: js_cli_node_check
  failed_when: false
  changed_when: false

- name: Treat too-old node as 'not present'
  when:
    - js_cli_node_check.rc == 0
    - js_cli_node_check.stdout is version('v18.0.0', '<')
  ansible.builtin.set_fact:
    js_cli_npm_check: { rc: 1 }   # force mise fallback
```

Trade-off: requires every host without mise+node to **also** install Node via mise; pulls in download time and disk on hosts that previously did nothing.

### B. Install Node via NodeSource on the affected hosts

Add a one-shot ansible task (or a host-scoped `extra_vars`) to register NodeSource's apt repo and install Node 20 LTS, replacing the system npm. Cleanest for full-fat Linux desktops; overkill for a NAS that only needs a couple of npm utilities.

### C. Skip `js_cli_tools` / `coding_agents` on the affected host

Add to the host's fleet config or per-host vars: `extra_skip_tags: js_cli_tools,coding_agents`. Honest — if the host doesn't actually need these tools, don't install them. Best for `ts_nas`-class hosts whose role profile is "just enough to be a fleet target".

### D. Install mise's npm and prepend it to PATH

`mise use -g node@lts` → `mise reshim` → `~/.local/share/mise/shims/npm` becomes available. The role's existing fallback already handles `js_cli_mise_bin` correctly, so step A would just be making the role *prefer* mise over a too-old system npm.

## How to verify the fix worked

```bash
# Re-run only the affected tags on the affected host (debug-friendly serial mode)
just fleet-apply-one ts_nas
# Look for: 'Tag 'js_cli_tools' had failures' should be GONE
grep -E "Tag.*failures" logs/fleet-apply/<RUN_ID>/ts_nas.log
```

Expected: no `Tag '...' had failures` lines, `failed=0` in every PLAY RECAP.

## Related

- `pitfalls/npm-postinstall-github-releases-hang.md` — different npm symptom (postinstall stuck on GitHub release download), same root cause family (npm-via-ansible footguns on China network + old Ubuntu LTS).
- The `coding_agents` role's `@openai/codex` install is the strictest engine requirement (Node ≥18); most other npm CLIs are Node ≥14 or ≥16. If you bump the threshold in fix path A, `v18` is the right floor for the current package set.
