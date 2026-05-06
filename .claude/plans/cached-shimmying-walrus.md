# Plan: Docker test images for `centos_server` profile

## Context

The `centos_server` chezmoi profile already exists (`.chezmoi.toml.tmpl:20`,
profile choices include `centos_server`) and has a dedicated dispatch branch in
`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl:134-142`. It
was added for a real corporate target (`yzhang-idc-server104` — CentOS Linux 7.9,
glibc 2.17, noRoot user). `pitfalls/centos7-noroot.md` documents the gate-
broadening fix that lets user-level GitHub-release fallbacks (`base`, `starship`,
`security_tools`, `rust_cargo_tools`) fire on RedHat-family boxes.

What we're missing is **install-test infrastructure** for this profile. The
existing `Dockerfile` / `docker-compose.yml` / `just docker-*` recipes are
Ubuntu-only (`FROM ubuntu:24.04`), so changes that affect the RedHat path can
only be validated by SSHing to the actual corporate box — slow, fragile, and
not reproducible.

This plan adds two RedHat-family Docker images (CentOS 7 + Rocky 9) each in
two flavors (noRoot=false and noRoot=true), wired into compose, the bats
smoke suite, and `just docker-*` recipes — same shape as the existing Ubuntu
matrix.

## Goals & non-goals

**Goals**
- Reproducible local install-test for `centos_server` profile: `just docker-test-centos7` / `just docker-test-rocky9`.
- Cover both the user's actual scenario (CentOS 7 + noRoot=true) and the modern path (Rocky 9 + sudo).
- Surface gaps in Debian-only ansible roles (`devtools`, `lazyvim_deps`, `docker`, `neovim`, `iac_tools`, etc.) so they show up as test failures we can tackle separately.

**Non-goals**
- Fixing the Debian-only roles. Those are a separate body of work; let them fail visibly under the new tests, then track via TODO.md / backlog/. (Roles already known to have RedHat support: `base`, `zsh`, `starship`, `ruby_gem_tools`, `rust_cargo_tools`, `security_tools`.)
- Running systemd inside containers. CentOS 7 / Rocky 9 base images don't have systemd; roles that use `ansible.builtin.systemd*` (`docker`, `rust_cargo_tools` pueued) already `ignore_errors: true` or are Debian-gated.
- Adding a `china` mirror variant for CentOS images. Out of scope for v1; CentOS 7 mirror story is moot post-EOL (vault is the only working source) and Rocky 9 already works against default mirrors from inside GFW.

## Files to add / modify

### New files

1. **`Dockerfile.centos7`** — `FROM centos:7`. Critical: rewrite `/etc/yum.repos.d/CentOS-*.repo` to point at `vault.centos.org` BEFORE first `yum install` (CentOS 7 EOL'd 2024-06-30 and `mirrorlist.centos.org` returns 404). Then `yum install -y curl sudo git python3` (note: CentOS 7 ships Python 3.6.8 as `python3` — bootstrap's `uv tool install --python 3.13 ansible-core` already handles this, see `run_once_before_00_bootstrap.sh.tmpl:299-302`). Mirror the rest of `Dockerfile` exactly (devuser + sudoers + COPY + chezmoi init with the same 17 `--prompt*` flags). Default `CHEZMOI_PROFILE=centos_server`.

2. **`Dockerfile.rocky9`** — `FROM rockylinux:9`. No vault redirect needed. Replace apt sections with `dnf install -y curl sudo git python3 --allowerasing` (curl-minimal conflict on Rocky 9). Default `CHEZMOI_PROFILE=centos_server`.

### Modified files

3. **`docker-compose.yml`** — add 5 services:
   - `centos7` — `Dockerfile.centos7`, `CHEZMOI_NO_ROOT=false`, `CHEZMOI_ALLOW_PARTIAL_FAILURE=true` (so Debian-only role failures don't abort).
   - `centos7-noroot` — `Dockerfile.centos7`, `CHEZMOI_NO_ROOT=true`. Closest match to the real corporate box. Profile gate: `centos`.
   - `rocky9` — `Dockerfile.rocky9`, `CHEZMOI_NO_ROOT=false`, `CHEZMOI_ALLOW_PARTIAL_FAILURE=true`. Profile gate: `rocky`.
   - `rocky9-noroot` — `Dockerfile.rocky9`, `CHEZMOI_NO_ROOT=true`. Profile gate: `rocky`.
   - `test-centos7` and `test-rocky9` — mirror the existing `test` service; run `bats /tmp/dotfiles-source/tests/smoke`. Profile gate: `test`. Per the Phase-1 finding, all 8 tests in `tests/smoke/docker_install.bats` are platform-agnostic, no test changes needed.

   Use `compose --profile <name>` gates exactly like the existing `desktop` / `china` / `test` services so default `docker compose up` still only builds the Ubuntu devbox.

4. **`justfile`** (extend the existing `# Docker` section, lines 8-49):
   - `docker-build-centos7` / `docker-build-rocky9` — build per service.
   - `docker-build-centos-all` — build all four CentOS-family services.
   - `docker-run-centos7` / `docker-run-centos7-noroot` / `docker-run-rocky9` / `docker-run-rocky9-noroot` — interactive shells.
   - `docker-test-centos7` / `docker-test-rocky9` — `docker compose --profile test run --build --rm test-centos7` (etc).
   - Extend `docker-build-all` to also build the four new services.
   - Extend `docker-clean` to `docker image rm dotfiles:centos7 dotfiles:centos7-noroot dotfiles:rocky9 dotfiles:rocky9-noroot 2>/dev/null || true`.
   - Extend `check-all` (line 266) to optionally include centos test runs (gate behind a flag — or leave as separate `just check-all-centos` to keep the default `check-all` runtime bounded).

5. **`README.md`** — under the existing Docker testing section (search for `just docker-test`), add a one-liner pointing at the new `just docker-test-centos7` / `just docker-test-rocky9` recipes and what they cover (CentOS 7 noRoot path = closest to corporate use case; Rocky 9 = modern RHEL-family). Keep it short — full details belong in `docs/this_repo/`.

6. **`docs/this_repo/architecture.md`** (or new `docs/this_repo/docker-testing.md` — verify which is the existing home of Docker docs first) — explain the matrix, why we have CentOS 7 vault redirect, why noRoot+sudo per image, and which roles are expected to fail on RedHat-family until their yum/dnf branches are added. Add nav entry to `mkdocs.yml` if a new file is created.

7. **`mkdocs.yml`** — only if (6) creates a new doc file. Add under "This Repo" section.

8. **`pitfalls/centos7-noroot.md`** — append a "How to repro locally" section pointing at `just docker-test-centos7` and `just docker-run-centos7-noroot`. Useful because anyone re-debugging the gate-broadening invariant can now boot a representative env in 60 seconds.

## Critical Dockerfile.centos7 details

CentOS 7 EOL on 2024-06-30 means the default repos in `centos:7` Docker image return 404. Required at the very top of the `RUN` chain, BEFORE any `yum install`:

```dockerfile
RUN sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo \
 && sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
```

Without this, the very first `yum install -y ca-certificates curl` fails with a DNS / 404 error and the whole layer collapses. The user's actual box may still be on a corporate mirror that hasn't redirected to vault — that's their admin's problem, but the Docker test must use vault.

`useChineseMirror=true` for CentOS 7 is intentionally **not** plumbed in this v1 — `vault.centos.org` is reachable from inside GFW; mirroring vault is a niche need.

## Why both noRoot=true and noRoot=false per image

| Service | What it tests |
|---|---|
| `centos7-noroot` | The actual corporate use case. User-level GitHub-release fallbacks in `base`, `starship`, `security_tools`, `rust_cargo_tools`. This is what `pitfalls/centos7-noroot.md` is about. Should mostly succeed. |
| `centos7` (sudo) | yum branches in `base`, `zsh`, `ruby_gem_tools`. Plus surfaces missing yum branches in Debian-only roles (`devtools` / `lazyvim_deps` / `docker` / `neovim` / `iac_tools`). `allowPartialFailure=true` keeps the run going. |
| `rocky9-noroot` | Same user-level path on glibc 2.34 — verifies fallbacks aren't accidentally pinned to glibc-2.17 musl variants when modern glibc is available. |
| `rocky9` (sudo) | Modern dnf path. Confirms gate-broadening from `os_family == "Debian"` to `in ["Debian", "RedHat"]` works on dnf-native distros, not just yum-on-CentOS-7. |

## Verification

After implementation, end-to-end test:

```bash
# Build and run the noRoot CentOS 7 path (the real corporate scenario)
just docker-test-centos7
# Expected: bats reports 8/8 passing inside the centos7-noroot image

# Modern RHEL path
just docker-test-rocky9
# Expected: bats reports 8/8 passing inside rocky9-noroot

# Interactive smoke check (sudo path, expect partial failures from Debian-only roles)
just docker-run-centos7
# Inside container:
#   chezmoi diff       # should be empty (idempotence)
#   command -v rg fd jq nvim starship zsh just bats   # all should resolve
#   ansible-playbook --version  # python version = 3.13.x

# Cleanup
just docker-clean
# Expected: all four new images removed alongside existing dotfiles:* images
```

Smoke-test pass criteria match the existing Ubuntu `test` service — bats TAP output, exit 0. If any of the 8 tests fail on RedHat-family, that's a bug to fix (likely in a Debian-only role missing a RedHat branch); track via `pitfalls/` or `TODO.md` per the project-knowledge-harness rules in `CLAUDE.md`.

## Reused patterns / utilities

- **Dockerfile shape**: copy verbatim from `Dockerfile` lines 7-29 (ARG block) and lines 96-145 (devuser + chezmoi init flag list). Only the OS-prep section (lines 30-94) changes.
- **compose service shape**: copy from `docker-compose.yml` lines 11-29 (`devbox`) for the regular services, lines 73-93 (`test`) for the test variants.
- **justfile recipe shape**: copy from `justfile` lines 13-49 — same one-liner pattern.
- **Dockerfile prompt-flag list**: must stay in sync with `.chezmoi.toml.tmpl` and `scripts/init/dotfiles_init.py` per `CLAUDE.md` "Dockerfile + dotfiles_init wrapper" invariant. The new Dockerfiles inherit the existing 17-flag block unchanged — no new prompts introduced, so `dotfiles_init.py doctor` parity is automatic.
- **`scripts/redact_secrets.py` DEFAULT_PATHS**: not affected; new files don't introduce a new agent-artifact prefix.

## Risk / out-of-scope notes

- **Debian-only roles will fail loudly under sudo path.** That's the point — better to surface than to hide. `allowPartialFailure=true` on the sudo services keeps runs going so we get a complete failure list. The list of roles needing yum/dnf branches (per Phase-1 explore): `devtools`, `lazyvim_deps`, `docker`, `neovim`, `nerdfonts`, `networking_tools`, `iac_tools`, `media_tools`, `llm_tools`, `js_cli_tools`, `bitwarden`, `coding_agents`, `gui_apps_linux`, `input_method`. Triage which ones are in scope for `centos_server` (it's a server profile, so `gui_apps_linux` / `input_method` / `nerdfonts` don't matter; `devtools` and `lazyvim_deps` definitely do).
- **Docker layer cache**: rebuilding all four images from scratch downloads two new base images (~250 MB total) and re-runs ansible from zero. First `docker-build-centos-all` will be slow (~10-15 min); subsequent runs hit cache.
- **Bootstrap apt-get fallbacks**: `run_once_before_00_bootstrap.sh.tmpl:170-175,212-216` install Linuxbrew deps + libffi/libyaml via apt-get, guarded by `command -v apt-get`. On CentOS, these silently skip — fine for Rocky 9 (Ruby/mise compile from `glibc-devel` shipped by base image), potentially a problem on CentOS 7 if mise tries to compile Ruby. If it bites, the fix is a sibling `command -v yum` branch in bootstrap; track separately if it surfaces.
