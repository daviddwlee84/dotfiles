# Shell Script Testing

How this repo tests shell code, the landscape of shell-testing tools, and when to reach for each.

---

## TL;DR for this repo

| Tool | Role | Scope |
|------|------|-------|
| [**bats-core**](https://github.com/bats-core/bats-core) | Behaviour / unit tests | `tests/unit/`, `tests/smoke/` |
| [**shellcheck**](https://www.shellcheck.net/) | Static analysis (bugs, bad quoting) | Pre-commit on `scripts/*.sh` (severity=warning) + `dot_config/{shell,bash}/` (severity=error); `just lint-shell` for broad warning sweep |
| [**shfmt**](https://github.com/mvdan/sh) | Formatter (consistency check) | Pre-commit on `scripts/*.sh` |

Run everything with `just check-all`. Run just the fast unit suite with `just bats`. See [the repo tests/ tree](#how-this-repo-structures-tests) below.

**What's intentionally _not_ in scope:** ansible-role tests, bootstrap / `run_once` tests, chezmoi-template expansion tests, Python script tests, GitHub Actions CI. Coverage is deliberately narrow — this is a personal dotfiles repo, not a library.

---

## The three shell-testing frameworks

Most people pick between Bats, ZUnit, and ShellSpec. Short version of when each makes sense:

### Bats (Bash Automated Testing System) — what this repo uses

A Bash testing framework. Tests go in `*.bats` files; each test is a `@test "name" { ... }` block. Provides `run`, `$status`, `$output`, `setup`, `teardown`, plus TAP / JUnit output for CI.

Pick Bats when:

- You mainly write Bash.
- You're testing CLI scripts or zsh scripts via **black-box** behaviour (run the command, check exit code + stdout/stderr).
- You want the most popular / best-documented shell testing ecosystem.

Not ideal when:

- You're testing zsh-specific functions (plugins, autoload, `${(P)var}`, parameter expansion flags) at the function level — Bats has no zsh affinity.
- You need mocking, coverage, or BDD grammar.

Companion libraries (optional, **not vendored here** to keep ceremony low):

- [`bats-assert`](https://github.com/bats-core/bats-assert) — `assert_equal`, `assert_output --partial`, etc.
- [`bats-file`](https://github.com/bats-core/bats-file) — file-system assertions.
- [`bats-support`](https://github.com/bats-core/bats-support) — shared helpers for the above.

### ZUnit — zsh-native

A [ZSH testing framework](https://github.com/zunit-zsh/zunit). Testcase syntax is similar to Bats but written in zsh, so zsh-specific constructs work naturally in both the tests and the code under test.

Pick ZUnit when:

- You're writing a zsh plugin, autoload function, or zsh-heavy library.
- You want the test harness to _be_ zsh rather than drive zsh from bash.

Trade-off: smaller ecosystem than Bats, needs [Revolver](https://github.com/molovo/revolver) as a dependency. Not installed by this repo.

### ShellSpec — full-featured, cross-shell

[ShellSpec](https://github.com/shellspec/shellspec) is a BDD framework that runs on dash, bash, ksh, zsh, and POSIX shells. Supports mocking, parameterised tests, parallel execution, coverage.

Pick ShellSpec when:

- You're shipping a shell library that must work across multiple shells.
- You want RSpec-style `Describe` / `It` / `When` / `The output should …` syntax.
- You need mocking or coverage reports.

Trade-off: heavier to learn than Bats; overkill for simple CLI behaviour checks.

### How to decide

| Situation | Pick |
|-----------|------|
| Bash CLI script, short & simple tests | **Bats** |
| zsh plugin / autoload-heavy code you want tested at the function level | ZUnit |
| Cross-shell library, or need mocking / coverage / BDD | ShellSpec |
| zsh CLI script tested via its external behaviour | **Bats** (drive zsh from bash, assert on output) |

This repo falls in the last row — most "zsh" code here is really "zsh script invoked as a CLI," so Bats is the simplest fit even though the code under test is zsh.

---

## How this repo structures tests

```
tests/
├── test_helper.bash          # shared helpers, sourced by every .bats file
├── unit/
│   ├── zsh_proxy.bats        # proxy helpers in 50_networking.zsh
│   ├── ghget.bats            # GitHub tree-URL parsing in 41_github.zsh
│   └── lan_scan.bats         # pure helpers in lan-scan.sh
└── smoke/
    └── docker_install.bats   # runs inside Docker after full install
```

### `tests/test_helper.bash`

Small helper library (<40 lines). Provides:

- `$REPO_ROOT` — absolute path to the chezmoi source.
- `setup_path_stub` — creates a temp dir and prepends it to `PATH`. Exposes the path via `$BATS_STUB_DIR` (not stdout), so the export survives — **do not wrap it in `$(...)`**. Command substitution runs the helper in a subshell and the `export PATH` is lost.
- `cleanup_path_stubs` — removes any stub dirs registered during the test.
- Default `teardown()` that calls `cleanup_path_stubs`. If a test file defines its own `teardown()`, call `cleanup_path_stubs` at the end to preserve cleanup.

### `tests/unit/zsh_proxy.bats`

Exercises the proxy helpers in `dot_config/zsh/tools/50_networking.zsh`:

- `$LOCAL_PROXY_URL` takes precedence over probing.
- Active Clash config (`mixed-port:` or `port:`/`socks-port:`) takes precedence over generic loopback probing.
- Port probe order: `7890 → 7891 → 1087 → 8118 → 8080`.
- `_ZSH_NET_PROXY_CACHE=none` when nothing responds.
- `__zsh_net_all_proxy_url` returns `$LOCAL_PROXY_SOCKS_URL` when set; falls back to the HTTP cache otherwise.
- `proxy-on` exports all six env vars (`http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `all_proxy`).
- Split HTTP / SOCKS wiring regression guard (commit `fa4c063`).
- `proxy-off` clears all six plus `NO_PROXY` / `no_proxy`, and drops cached detection state.
- `proxy-status` exit codes: `1` when unavailable, `0` when available.

Key technique: each test runs `zsh -f -c '...'` (no startup files) so the in-file cache (`$_ZSH_NET_PROXY_CACHE`) can't leak between tests, and `nc` is stubbed via a temp dir on `PATH` — no real network traffic.

### `tests/unit/ghget.bats`

Pins URL parsing for `ghget` in `dot_config/zsh/tools/41_github.zsh`:

- Rejects missing / non-GitHub / `/blob/` (file, not tree) URLs with exit 1.
- For valid URLs, checks that `owner`, `repo`, `branch`, and the subdir path all reach the `curl` + `tar` invocations intact. Query strings and trailing slashes are stripped.
- Refuses to overwrite an existing destination directory before touching the network.

Key technique: `curl` and `tar` are stubbed with bash scripts that log their args to `$CAPTURE_LOG`. The `tar` stub also fabricates the expected extracted directory (reading `-C` target and the last positional) so the post-extract `mv` in `ghget` succeeds — no real network, no real tarball.

### `tests/unit/lan_scan.bats`

Pins pure helpers in `dot_config/television/executable_lan-scan.sh`:

- `is_usable_ip` — accepts normal host IPs; rejects link-local (`169.254/16`), multicast (`224–239/4`), broadcast, network address, and `.0` / `.255` in the host octet.
- `vendor_for_mac` — normalises colon / dash / no-sep MAC formats, looks up the 6-hex prefix in an nmap-style OUI database.

Key technique: the script dispatches at load time (line 325+), so bare `source` runs the `all` subcommand and tries to probe the network. Work around by sourcing with `clean` as the first positional arg against an isolated `$XDG_CACHE_HOME` — `clean` is harmless under an isolated cache dir, and the function definitions remain in scope afterwards.

### `tests/smoke/docker_install.bats`

Runs inside the Dockerfile-built test image after `chezmoi apply` + ansible have completed. Asserts post-install state:

- `chezmoi apply` is idempotent (re-apply produces empty `chezmoi diff`).
- `zsh -n` passes on `~/.zshrc`, `~/.zshenv`, and every `~/.config/zsh/**/*.zsh`.
- `nvim --headless "+lua print('ok')" +qa` exits 0.
- Core CLI tools on `PATH`: `nvim rg fd fzf zsh just bats`.
- oh-my-zsh plugins present (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions`).
- Unit tests pass under the container's zsh (catches "works on my Mac" regressions).

Invoked by `just docker-test` → `docker compose run --build --rm test` → `bats /tmp/dotfiles-source/tests/smoke`.

---

## Running tests

```bash
# Fast feedback loop (no Docker, no network, sub-second)
just bats

# Smoke tests inside a clean Ubuntu container (slow — builds image)
just docker-test

# Everything: ansible syntax + pre-commit + bats + docker-test
just check-all
```

---

## Patterns worth reusing

### Testing zsh code from bats

Bats is bash-based, so drive zsh as a subprocess. Use `zsh -f -c 'source FILE; <call>'` to skip startup files (isolates the code under test) and capture output via `run` or `$(...)`:

```bash
@test "my zsh function does X" {
  result="$(zsh -f -c "
    source '$REPO_ROOT/dot_config/zsh/tools/my_file.zsh'
    my_function arg1 arg2
  ")"
  [ "$result" = "expected" ]
}
```

### Stubbing external commands

Prepend a temp dir to `PATH` containing a fake binary:

```bash
@test "probe order regression" {
  setup_path_stub   # populates $BATS_STUB_DIR, updates $PATH

  cat > "$BATS_STUB_DIR/nc" <<'EOF'
#!/usr/bin/env bash
port=""
while [ $# -gt 0 ]; do port="$1"; shift; done
[ "$port" = "$EXPECT_PORT" ] && exit 0 || exit 1
EOF
  chmod +x "$BATS_STUB_DIR/nc"

  EXPECT_PORT=1087 zsh -f -c "source '$REPO_ROOT/.../file.zsh'; my_probe"
}
```

Bats runs every `@test` block in its own subshell, so `PATH` modifications don't leak across tests. `cleanup_path_stubs` (default `teardown`) removes the temp dirs.

### Asserting zsh variables from bash

Inside `zsh -f -c '...'`, use zsh indirect expansion (`${(P)v}`) to print a variable named in another variable:

```bash
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
  printf '%s=%s\n' "$v" "${(P)v}"
done
```

Then bats asserts on the `$output`:

```bash
[[ "$output" == *"http_proxy=http://test:1234"* ]]
```

---

## shellcheck + shfmt

[shellcheck](https://www.shellcheck.net/) is a static analyser for shell scripts. [shfmt](https://github.com/mvdan/sh) is a formatter / format-check. Both run via pre-commit in this repo. For generic pre-commit mechanics (cache location, `uv`-managed bootstrap Python, debugging broken hook envs), see [`docs/tools/pre-commit.md`](../tools/pre-commit.md).

Pre-commit hook sources (see `.pre-commit-config.yaml`):

- [`shellcheck-py`](https://github.com/shellcheck-py/shellcheck-py) — ships a Python-installable wheel of shellcheck, so pre-commit environments don't need a system-wide `shellcheck` binary.
- [`pre-commit-shfmt`](https://github.com/scop/pre-commit-shfmt) — pre-commit wrapper around `shfmt` with no Go toolchain required.

### Other config-file syntax checks

In addition to shell tooling, `.pre-commit-config.yaml` runs these [pre-commit/pre-commit-hooks](https://github.com/pre-commit/pre-commit-hooks) validators:

- `check-yaml` — ansible playbooks, role definitions, docker-compose, pre-commit itself.
- `check-toml` — TV cable channel configs, starship, yazi, alacritty, etc. `.tmpl` files are excluded because chezmoi's `{{ ... }}` go-template tokens aren't valid TOML until rendered.
- `check-json` — VS Code settings, claude config, lazyvim lockfile, etc.
- `check-merge-conflict`, `check-added-large-files`, `detect-private-key`, `end-of-file-fixer`, `trailing-whitespace`.

Ansible **playbook syntax** is checked via `just ansible-syntax-check` / `just lint`, not pre-commit — running a full playbook parse on every commit is too slow for the pre-commit hot path. Run `just lint` manually before pushing ansible-touching changes.

Hook scope (see `.pre-commit-config.yaml`): two tiers.

1. **`^scripts/[^/]+\.sh$`** at `--severity=warning` — the original strict scope; always green.
2. **`^dot_config/(shell/[^/]+\.sh|bash/[^/]+\.bash)$`** at `--severity=error` — added 2026-05. Catches actual bugs (e.g. SC2142 alias-with-positional-param) while we gradually clean up the ~40 preexisting warnings the broader scope surfaces. Drop to `--severity=warning` once `just lint-shell` is clean — tracked in [`backlog/shellcheck-broaden-shared-scope.md`](../../backlog/shellcheck-broaden-shared-scope.md).

Always excluded:

- `dot_config/zsh/**/*.zsh` — zsh-specific syntax (`(( ... ))` math, `${(P)v}` expansion flags, `print -u2`, `emulate -L zsh`, `zmodload`) trips shellcheck's bash parser and produces too many false positives.
- `*.sh.tmpl` / `*.bash.tmpl` — chezmoi go-template tokens (`{{ if eq .profile "macos" }}`) look like unbalanced braces to shellcheck.
- `scripts/adhoc/*.sh` — experimental / throwaway scripts by convention.

If a zsh file needs static analysis later, the best options are:

- Run shellcheck with `# shellcheck shell=bash` and manually silence known-false positives — tedious.
- Switch to a zsh-aware linter (there isn't a widely adopted one).
- Or just write a Bats test that covers the behaviour you care about.

Quick commands:

```bash
# Run both shellcheck hook entries (scripts/ + shared) on all files
pre-commit run shellcheck --all-files

# Run only the broader (shared shell modules) scope at severity=error
pre-commit run shellcheck-shared --all-files

# Broad warning sweep across scripts/ + dot_config/{shell,bash}/ —
# exits non-zero on findings; useful for gradual cleanup. Uses uvx
# shellcheck-py when system shellcheck isn't on PATH.
just lint-shell

# Run only shfmt
pre-commit run shfmt --all-files

# shfmt is in -w mode (writes in place via the hook) — to format manually:
shfmt -i 2 -ci -bn -w scripts/*.sh
```

---

## Adding a new test

1. Decide unit vs smoke:
   - Pure logic with stub-able inputs → `tests/unit/`.
   - Assertions about post-install system state → `tests/smoke/`.
2. Create `tests/unit/<thing>.bats` (or smoke/). Start with:
   ```bash
   #!/usr/bin/env bats
   load "../test_helper.bash"

   @test "brief description" {
     run some-command
     [ "$status" -eq 0 ]
   }
   ```
3. Run `just bats` (or `just docker-test`) to verify.
4. If the test needs a stub, use `setup_path_stub` + `$BATS_STUB_DIR`.

Rule of thumb for deciding whether a test is worth adding: **would a silent regression here cost me more than ten minutes to diagnose?** If no, skip the test. Personal dotfiles don't need 80% coverage.

---

## References

- [bats-core docs](https://bats-core.readthedocs.io/) · [bats-assert](https://github.com/bats-core/bats-assert) · [bats-file](https://github.com/bats-core/bats-file) · [bats-support](https://github.com/bats-core/bats-support)
- [ZUnit repo](https://github.com/zunit-zsh/zunit) (needs [Revolver](https://github.com/molovo/revolver))
- [ShellSpec docs](https://shellspec.info/) · [ShellSpec repo](https://github.com/shellspec/shellspec)
- [shellcheck wiki](https://www.shellcheck.net/wiki/) · pre-commit hook: [shellcheck-py](https://github.com/shellcheck-py/shellcheck-py)
- [shfmt flags](https://github.com/mvdan/sh/blob/master/cmd/shfmt/shfmt.1.scd) · pre-commit hook: [pre-commit-shfmt](https://github.com/scop/pre-commit-shfmt)
- Install location in this repo: `dot_ansible/roles/devtools/tasks/main.yml` (bats-core is cross-platform; no companion libraries installed by default).
