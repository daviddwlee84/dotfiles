# `centos_server` profile on a noRoot CentOS 7 box installs nothing

## Symptom

Run `chezmoi apply` on a CentOS Linux 7.9 box where the user has no
`sudo` (typical corporate/data-center development server):

```
$ sudo -v
sudo: PAM account management error: Permission denied
sudo: a password is required
```

`chezmoi apply` completes cleanly, ansible reports `0 failed`, configs
deploy under `~/.config/`, but `command -v rg fd jq nvim starship`
returns nothing. The dotfiles-deployed `~/.zshrc` references binaries
that don't exist; opening a new shell prints `command not found` for
half the prompt.

## Root cause

The Linux ansible roles have two parallel install paths for each tool:

1. **System-level** (`apt:` / `yum:`) — gated by `become: true, tags:
   [sudo]`. Skipped on `noRoot=true` via `--skip-tags sudo`. Correct.
2. **User-level fallback** — downloads pre-built binaries from GitHub
   releases into `~/.local/bin/`, no sudo required.

The user-level fallback is the one that's *supposed* to fire on a
noRoot box. It was historically gated on
`when: ansible_facts["os_family"] == "Debian"` — which made sense when
the only Linux profiles were `ubuntu_*`, but is wrong as soon as a
RedHat-family box (CentOS, Rocky, Alma) shows up. The user-level path
has no apt-specific behaviour — it's `curl | tar | install`. There's
no reason for it to be gated on the package-manager family.

So on CentOS 7 with `noRoot=true`, both paths are gated out:

- system-level: skipped by `--skip-tags sudo`
- user-level: skipped by `os_family == "Debian"` predicate

The role is a no-op and the user gets a working `~/.zshrc` pointing at
binaries that were never installed.

## Fix

Broaden the user-level (non-sudo-tagged) `when:` predicates from:

```yaml
when: ansible_facts["os_family"] == "Debian"
```

to:

```yaml
when: ansible_facts["os_family"] in ["Debian", "RedHat"]
```

Applied across `dot_ansible/roles/{base,starship,security_tools,rust_cargo_tools}/tasks/main.yml`
when the `centos_server` profile was introduced. The
`Re-check if X is installed` + `Install X from GitHub releases
(user-level, no sudo)` block pattern is the canonical shape — every
file that has it needs the broadening.

**Don't** broaden the sudo-tagged `apt:` blocks the same way — those
have `become: true, tags: [sudo]` and use `ansible.builtin.apt:` which
fails on RedHat. Either leave them alone (skipped under `--skip-tags
sudo` anyway) or add a parallel `RedHat` block with `ansible.builtin.yum:`.

## CentOS 7-specific notes (glibc 2.17)

CentOS 7 ships glibc 2.17 (released 2012). Many modern GitHub-release
binaries are built on Ubuntu 22.04 or 24.04 (glibc 2.35+) and crash
with:

```
./tool: /lib64/libc.so.6: version `GLIBC_2.29' not found (required by ./tool)
```

### CentOS 7 also ships Python 3.6.8 — bootstrap pins ansible to Python 3.13

Symptom on a fresh CentOS 7 box:

```
[INFO] Installing ansible via uv...
Resolved 10 packages in 4m 29s
Installed 10 packages …
 + ansible-core==2.11.12          ← suspicious: latest is 2.18+
…
[INFO] Installing ansible-galaxy collections...
[WARNING]: Skipping Galaxy server https://galaxy.ansible.com/api/. Got an
unexpected error when getting available versions of collection community.general:
'/api/v3/plugin/ansible/content/published/collections/index/community/general/versions/'
ERROR! Unexpected Exception, this is probably a bug:
'/api/v3/plugin/ansible/content/published/collections/index/community/general/versions/'
[ERROR] Failed to install community.general collection.
chezmoi: 00_bootstrap.sh: exit status 1
```

Two compounding issues:

1. **`uv tool install` defaults to system Python.** On CentOS 7 that's
   Python 3.6.8. uv resolves `ansible-core` to **2.11.12** — the last
   version with Py3.6 support, released August 2021.
2. **2.11.12 predates Galaxy NG.** `galaxy.ansible.com` was migrated to
   the Pulp/Galaxy-NG backend; ansible-core 2.11 hits the new
   `/api/v3/plugin/ansible/content/published/...` endpoint and throws
   `KeyError(<that URL string>)` because it expects the legacy v2
   shape. Output makes it look like a network/proxy error — it's not.
   The proxy hint in the bootstrap script's error message is a red
   herring on CentOS 7.

**Fix (already in `run_once_before_00_bootstrap.sh.tmpl`):** install
ansible with `uv tool install --force --python 3.13 ansible-core`. uv
auto-fetches a python-build-standalone interpreter (statically linked,
glibc-2.17 compatible) and pulls modern ansible-core (2.18+) that
speaks Galaxy NG. Same pattern as `pre-commit` in
`dot_ansible/roles/security_tools/tasks/main.yml`.

The bootstrap also detects an existing ansible install on Python <3.10
and force-reinstalls — so a box that previously bootstrapped with the
old line auto-heals on the next `chezmoi apply`. If you want to nuke
manually: `uv tool uninstall ansible-core && rm -rf
~/.local/share/uv/tools/ansible-core`.



The user-level fallbacks in `base/tasks/main.yml` already prefer
**musl** assets where upstream offers them — `ripgrep`, `fd`, `lnav`
all ship `*-unknown-linux-musl.tar.gz` variants that are statically
linked and ignore glibc version. Those are fine on CentOS 7.

Tools that ship glibc-only binaries (some Go releases, some Rust
releases without musl variants) will fail. Workarounds, in order of
preference:

1. **Cargo source build** — `cargo install <crate>` works on CentOS 7
   via the user's mise/cargo toolchain (`rust_cargo_tools` role
   already sets this up).
2. **Older release pin** — find a release built before the upstream
   project moved to a newer Ubuntu CI, pin to it.
3. **Skip on CentOS 7** — for tools that aren't critical, gate the
   block on `ansible_distribution_major_version != "7"` and live
   without it.

If the box gets rebuilt as Rocky/Alma 8 or 9 (glibc 2.28 / 2.34), most
of these go away — the gate-broadening fix above is still correct on
those.

## Required preconditions on a noRoot CentOS box

The dotfiles can't install **everything** without sudo. On
`centos_server` + `noRoot=true`, verify before running `chezmoi apply`:

- `command -v zsh` resolves — `zsh` package install needs sudo. Most
  corporate CentOS 7 boxes ship zsh; if not, ask the admin to
  `yum install zsh`.
- `command -v git` resolves — same story.
- `chsh -s "$(command -v zsh)"` — depends on the box's chsh policy
  (usually no sudo needed but `/etc/shells` must list zsh's path).

## Migration note

If/when this CentOS 7 box gets rebuilt as Rocky/Alma 8 or 9 (or any
modern RedHat-family distro), the gate-broadening change in this fix
remains correct (`os_family == "RedHat"` still matches). The
glibc-2.17 caveat goes away. The `yum:` blocks added to `base`,
`zsh`, `ruby_gem_tools` continue to work — `yum:` is an alias for
`dnf:` on RHEL 8+ via the ansible compatibility shim.

## How to repro locally (Docker)

Two `docker-compose` images mirror the corporate CentOS 7 box and a
modern Rocky 9 sister target:

```bash
# Closest reproduction of the actual box (CentOS 7 + noRoot=true)
just docker-run-centos7-noroot
# Inside container, the user-level fallbacks should have populated
# ~/.local/bin: command -v rg fd jq starship zsh just bats

# Modern dnf-native sister case (Rocky Linux 9, glibc 2.34)
just docker-run-rocky9-noroot

# Bats smoke suite under both
just docker-test-centos-all
```

The CentOS 7 Dockerfile (`Dockerfile.centos7`) redirects
`/etc/yum.repos.d/CentOS-*.repo` to `vault.centos.org` since CentOS 7
EOL'd 2024-06-30 and the default `mirrorlist.centos.org` returns 404.
The user's actual corporate box may still be on an internal mirror;
the vault redirect only matters for the Docker reproduction.

Use the sudo flavor (`just docker-run-centos7`) when you need to
exercise the `yum:` task branches in `base`/`zsh`/`ruby_gem_tools` —
just be aware that Debian-only roles (`devtools`, `lazyvim_deps`,
`docker`, etc.) still lack yum branches and will fail; those services
are configured with `allowPartialFailure=true` so the apply finishes
and you get a complete failure list.

## Related

- `dot_ansible/roles/base/tasks/main.yml` — canonical
  `Re-check if X / Install X from GitHub releases (user-level)`
  pattern.
- `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`
  — `centos_server` profile branch + `--skip-tags sudo` on
  `noRoot=true`.
- `Dockerfile.centos7` / `Dockerfile.rocky9` + `docker-compose.yml`
  `centos7*` / `rocky9*` services — local install-test infrastructure.
- `pitfalls/ansible-missing-sudo-tag.md` — sibling pitfall: the
  inverse of this one (sudo task without the `[sudo]` tag, fails on
  noRoot).
