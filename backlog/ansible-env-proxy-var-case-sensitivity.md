# `ansible-playbook` env-var lookup is case-sensitive — proxy var skipped on uppercase-only hosts

**Status**: P2
**Effort**: S
**Related**: `TODO.md` · `dot_ansible/roles/neovim/tasks/main.yml` · `dot_ansible/roles/devtools/tasks/main.yml` (every `get_url:` block) · `pitfalls/centos7-idc-slow-broken-installs.md`

## Context

Surfaced 2026-05-13 while verifying the centos7-noroot.md sweep on a real
CentOS 7 IDC box (`idc-server104`). The newly-fixed neovim role's
`Get latest neovim-releases tag` URI task and the subsequent
`Download Neovim tarball` `get_url:` task both timed out with:

```
FAILED - RETRYING: [localhost]: Download Neovim tarball (3 retries left).
[ERROR]: Task failed: Module failed: Request failed: <urlopen error [Errno 110] Connection timed out>
url: https://github.com/neovim/neovim-releases/releases/download/v0.12.2/nvim-linux-x86_64.tar.gz
```

— but the same URL via `curl` from the same shell completed in ~4 minutes
(slow, but no timeout). Confirmed:

- `env | grep -i proxy` shows uppercase **only**: `HTTPS_PROXY=http://127.0.0.1:7891`
- `getent ahostsv4 github.com` resolves; raw TCP to `140.82.x.x:443` works.
- Removing the proxy (`unset HTTPS_PROXY`) makes curl fail too — proxy is
  load-bearing for github.com from this network.

The role's `environment:` block reads:

```yaml
environment:
  http_proxy: "{{ lookup('env', 'http_proxy') | default('', true) }}"
  https_proxy: "{{ lookup('env', 'https_proxy') | default('', true) }}"
```

`lookup('env', 'https_proxy')` is **case-sensitive** in the underlying
Python `os.environ.get('https_proxy')`. With only the uppercase variant
exported, the lookup returns the empty string → the `environment:` block
sets `https_proxy=""` (which `requests` / `urllib` treat as "no proxy"),
overriding any inherited uppercase one.

This is a no-op on hosts that export both cases (most modern shells do),
but for environments that only set the canonical
[`*_proxy`](https://www.gnu.org/software/wget/manual/html_node/Proxies.html)
uppercase form (corporate IT scripts, container orchestrators), every
`get_url` / `uri` task in the role layer that ships this pattern silently
fails to use the proxy.

## Investigation

What's already known:

- `lookup('env', NAME)` is `os.environ.get(NAME, '')` — case-sensitive,
  no fallback.
- The pattern is repeated across at least 6 `get_url` / `uri` tasks in
  `neovim` (1) + `devtools` (5+: btop, bat, yazi, zellij, lnav, etc. via
  the `environment:` block on the apt task — but those don't actually use
  it on the user-level fallback). Need a real grep to count.
- Curl reads both cases (`HTTPS_PROXY` first, then `https_proxy`). Python
  `urllib.request.getproxies()` reads BOTH cases by default but
  `ansible.builtin.get_url` overrides via the `environment:` keyword.
- The dotfiles' shared shell layer
  (`dot_config/shell/99_local_proxy.zsh` and similar) doesn't normalize
  to lowercase when populating proxy vars — they're whatever the user /
  IT set.

Same trap probably bites every `get_url` block I just broadened in the
centos7-noroot.md sweep. Hosts that don't need a proxy are unaffected;
hosts that need one and only export uppercase will see silent timeouts.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. Lookup chain `lower or upper`** in every `environment:` block | Minimal blast radius; explicit per-task | Repeated YAML in ~6+ tasks; easy to forget on new ones |
| **B. Set both cases at process level** in the chezmoi run-script before `ansible-playbook` | Fix-once-for-everyone; matches curl semantics | Requires touching `run_onchange_after_20_ansible_roles.sh.tmpl` + may conflict with explicit per-task `environment:` overrides |
| **C. Drop the `environment:` block entirely and let inherited proxy vars flow through** | One-line simplification | Loses the explicit "we honour proxy" signal in role code; relies on ansible-controller's environment having both cases |
| **D. New role helper task `Set proxy environment for downloads`** that exports both cases as facts, then reference `{{ proxy_env }}` in every `environment:` | DRY; single source of truth | More YAML scaffolding for 1-line behaviour |

A is closest to the existing pattern; B is closest to "fix the root cause".
C is risky (the explicit `environment:` block's other purpose is to
DOCUMENT the proxy dependency for code readers).

## Current blocker / open questions

- Does `lookup('env', 'X')` accept a list with fallback? Need to test
  `lookup('env', 'https_proxy', 'HTTPS_PROXY')` — Jinja2 `lookup` plugin
  signature varies across ansible versions.
- Should the chezmoi run-script normalize at the controller level
  (Option B) BEFORE per-task overrides? If so, `environment:` blocks in
  roles become redundant — drop them OR keep as documentation.
- Backwards compat: hosts that have both cases set with DIFFERENT values
  would change behaviour. Audit the fleet for such cases first
  (expectation: zero, but verify).

## Decision (if any)

Not yet decided. Probably **A + B**: B fixes the controller side
(harmless on hosts with both already set), A keeps role tasks
explicit. Land in same commit as the next `centos7-noroot.md` follow-up.

## References

- [Python `os.environ.get`](https://docs.python.org/3/library/os.html#os.environ)
- [ansible `lookup` env plugin](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/env_lookup.html)
- [`pitfalls/centos7-idc-slow-broken-installs.md`](../pitfalls/centos7-idc-slow-broken-installs.md) — the wider IDC slow-network context that surfaced this.
- 2026-05-13 manual repro on `idc-server104` (CentOS 7.9, glibc 2.17, sudo, slow link via Clash proxy at `127.0.0.1:7891`).
