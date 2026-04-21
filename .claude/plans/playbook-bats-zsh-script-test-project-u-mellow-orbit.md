# Lightweight shell testing for dotfiles (bats + shellcheck + shfmt)

## Context

This is a personal dotfiles repo. Bats is already installed via the `devtools` ansible role (previous plan: `.claude/plans/bats-snuggly-volcano.md`), but nothing in the repo actually uses it — the sole "test" today is `docker-compose.yml` running ~30 inline bash assertions on tool/config presence.

Goals for this pass, per the user's scope decision:

- **Protect against painful regressions only** — proxy helpers in `dot_config/zsh/tools/50_networking.zsh` are the one piece of pure logic that is used daily, silent when broken, and non-trivial (env precedence + port probing + SOCKS split).
- **Lint cheaply** — shellcheck + shfmt on commit catch a whole class of bugs per-bug more cheaply than writing tests.
- **Keep ceremony minimal** — no vendored `bats-assert`/`bats-file`/`bats-support` submodules; no CI; no fixture frameworks; no refactors of shell code purely for testability.

What's explicitly **not** in scope: git-helper unit tests (`gundo`/`gcam-amend`), Python redact-script tests, ansible-role testing, bootstrap-script testing, chezmoi-template expansion tests, GitHub Actions CI.

## Files to add

### 1. `tests/test_helper.bash`

Tiny shared helper. Sourced by every `.bats` file. Provides:

- `REPO_ROOT` pointing at the chezmoi source dir (derived from `BATS_TEST_DIRNAME`).
- `setup_path_stub()` — creates a temp dir, prepends to `PATH`, returns path so individual tests can drop fake binaries (e.g. a fake `nc`).
- `teardown` hook clears any temp dirs registered via `_BATS_STUBS`.

Keep it under ~40 lines. No external libraries.

### 2. `tests/unit/zsh_proxy.bats`

Tests `dot_config/zsh/tools/50_networking.zsh` — the single highest-risk pure-ish module. Each test sources the file inside a fresh `zsh -c` subshell so cache state (`_ZSH_NET_PROXY_CACHE`) doesn't leak. Plan for ~8 tests total, not 20:

1. `__zsh_net_detect_proxy` picks up `$LOCAL_PROXY_URL` verbatim, skipping probe.
2. `__zsh_net_detect_proxy` probes ports in order `7890 7891 1087 8118 8080` when `$LOCAL_PROXY_URL` unset — fake `nc` (PATH stub) returns success only on a chosen port; expect `_ZSH_NET_PROXY_CACHE=http://127.0.0.1:<port>`.
3. `__zsh_net_detect_proxy` sets `_ZSH_NET_PROXY_CACHE=none` when no port responds.
4. `__zsh_net_all_proxy_url` returns `$LOCAL_PROXY_SOCKS_URL` when set; falls back to the HTTP cache otherwise.
5. `proxy-on` exports all six env vars (`http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `all_proxy`) — assert via `zsh -c '... ; proxy-on -q; env | grep -c "_proxy\|_PROXY"'`.
6. `proxy-on` with split `LOCAL_PROXY_URL` + `LOCAL_PROXY_SOCKS_URL` wires HTTP and SOCKS to different URLs (regression guard for the recent `fa4c063` SOCKS5 split).
7. `proxy-off` clears all six + `NO_PROXY`/`no_proxy`.
8. `proxy-status` exits `1` when no proxy available; exits `0` when available.

Mocking strategy for `nc`: write `#!/usr/bin/env bash\n[[ "$3" == "${EXPECT_PORT}" ]] && exit 0 || exit 1` into the PATH stub. No network required. Each test sets `EXPECT_PORT` in its env.

### 3. `tests/smoke/docker_install.bats`

A deliberately small smoke suite meant to run **only** inside the Docker test container (it asserts things that are only true post-install). Port over just the painful-regression checks from `docker-compose.yml` lines 88–117 — drop the ones that are trivially obvious (e.g. "git exists"). Target ~8 tests:

1. `chezmoi apply` is idempotent — after apply, `chezmoi diff` exits 0 with empty output.
2. `zsh -n ~/.zshrc` — top-level zsh syntax valid.
3. `zsh -n ~/.zshenv` — same.
4. `~/.config/zsh` directory exists and at least one `*.zsh` file in it parses clean (`zsh -n`).
5. `~/.config/nvim/init.lua` exists and `nvim --headless "+lua print('ok')" +qa` exits 0.
6. `nvim`, `rg`, `fd`, `fzf`, `zsh`, `just`, `bats` are on `PATH`.
7. oh-my-zsh plugin dirs exist (autosuggestions, syntax-highlighting, completions).
8. `bats tests/unit` passes inside the container (nested bats — sanity check that unit tests also run under the installed zsh).

The existing `command:` block in `docker-compose.yml` is replaced with `bats /chezmoi/tests/smoke/docker_install.bats` (container mounts/copies repo at `/chezmoi`). Same behavior as today, clearer failures, TAP output.

### 4. `.pre-commit-config.yaml` — add shellcheck + shfmt

Append two hooks. Use the upstream mirror repos that don't require local installs:

```yaml
- repo: https://github.com/shellcheck-py/shellcheck-py
  rev: v0.10.0.1
  hooks:
    - id: shellcheck
      files: '^(scripts/.*\.sh|dot_config/zsh/.*\.zsh|.*\.sh\.tmpl)$'
      args: [--shell=bash, --severity=warning]
      # chezmoi templates contain {{ ... }} — shellcheck tolerates them as
      # regular tokens; lint --severity=warning to avoid style churn.

- repo: https://github.com/scop/pre-commit-shfmt
  rev: v3.10.0-2
  hooks:
    - id: shfmt
      files: '^(scripts/.*\.sh|dot_config/zsh/.*\.zsh)$'
      args: [-i, "2", -ci, -bn, -d]
      # -d = diff mode, fails but doesn't rewrite; run with -w manually to fix.
```

Exclusions to note in the hook config:

- Zsh-only syntax (e.g. `[[ $a =~ $b ]]` with zsh arrays, `(( ... ))` arithmetic, `print -u2`) will trip shellcheck under `--shell=bash`. If any zsh file fails cleanly, add it to `exclude:` rather than silencing the hook globally.
- `.tmpl` files containing `{{ chezmoi }}` template syntax: scope shellcheck to the shell portions only; if noisy, narrow `files:` to drop `.tmpl`.

First run will produce a pile of warnings. Fix the trivial ones (quote expansions, `$(( ... ))` typos) in the same commit; add `# shellcheck disable=SC....` where intentional.

### 5. `justfile` — add two targets

After the existing `test:` target (line 194):

```make
# Run bats unit tests (fast, no Docker)
bats:
    bats tests/unit

# Run everything: lint + syntax + unit tests + docker smoke
check-all: lint bats docker-test
```

Don't redefine `test:` — leave the existing `test: docker-test` alias alone.

### 6. Docs

- **README.md** — "What You Get" section already lists `bats` under devtools. Add one sentence under a new "Testing" subsection: `Run \`just bats\` for unit tests; \`just docker-test\` for smoke tests in a clean container.`
- **CLAUDE.md** — add a top-level "Testing" section near "Development":
  - `just bats` runs unit tests (fast, no Docker).
  - `just docker-test` runs smoke tests in a clean Ubuntu container.
  - shellcheck + shfmt run via pre-commit.
  - What is tested / what is not (link to this plan or summarize in 3 bullets).
- **docs/** — no new doc file. Keep it to README + CLAUDE.md.

## Critical files to reuse / reference

- `dot_config/zsh/tools/50_networking.zsh` — code under test. Functions: `__zsh_net_detect_proxy` (L87), `__zsh_net_all_proxy_url` (L107), `withproxy` (L116), `try_direct_then_proxy` (L134), `proxy-on` (L147), `proxy-off` (L173), `proxy-status` (L179), `proxy-refresh` (L206). Recent commit `fa4c063` split HTTP/SOCKS URLs — tests should pin that behavior.
- `docker-compose.yml:88-117` — current inline smoke assertions, the source material for `tests/smoke/docker_install.bats`.
- `dot_ansible/roles/devtools/tasks/main.yml` — bats install location (bats-core on macOS, apt/user-level on Linux). No changes needed; already installs bats across all platforms.
- `.pre-commit-config.yaml` — existing hooks: gitleaks, trailing whitespace, check-executables-have-shebangs. Add shellcheck + shfmt alongside.
- `justfile:194` — existing `test:` target (`test: docker-test`). New `bats:` + `check-all:` targets go right after.

## Verification

End-to-end, from repo root:

```bash
# 1. Unit tests (no Docker, no network)
just bats
# Expect: ~8 tests pass in <1s.

# 2. Smoke tests inside container (full apply + checks)
just docker-test
# Expect: ~8 bats tests pass; TAP output visible in logs.

# 3. Lint on all existing shell files
pre-commit run shellcheck --all-files
pre-commit run shfmt --all-files
# Expect: clean (after first-pass fixes) or known ignores only.

# 4. Combined
just check-all
# Expect: all of the above green.

# 5. Sanity check: break a proxy function and confirm the suite catches it
# Temporarily change port order in 50_networking.zsh, run `just bats`, revert.
```

Not verified here: CI, macOS-only paths (manual `just bats` on the Mac covers it), or anything that requires a real proxy server.

## Non-goals (explicit)

- No `bats-assert` / `bats-file` / `bats-support` submodules. Plain bats built-ins (`[ ]`, `run`, `$status`, `$output`) are enough for eight tests.
- No git-helper tests. `gundo`/`gcam-amend` are simple; the cost of scaffolding throwaway git repos per test exceeds the regression risk.
- No GitHub Actions. If the user later wants CI, it's a separate ~15-line workflow calling `just check-all`.
- No refactors of `50_networking.zsh`. Tests exercise it as-is.
- No Python tests for `scripts/redact_specstory.py`. Gitleaks is the authority; the wrapper is thin.
