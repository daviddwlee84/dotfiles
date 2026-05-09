# CentOS 7 (`idc-server104`) chezmoi-apply failures — fix plan

## Context

User `yczhang` ran `chezmoi update --apply --init` on a CentOS 7.9 box (`centos_server` profile, passwordless sudo) and hit five ansible task failures:

| # | Task | Error | Root cause |
|---|------|-------|------------|
| 1 | `lazyvim_deps : Install tree-sitter-cli via cargo (fallback)` | `Unable to find libclang … libclangAST.so.7 cannot open` | Cargo path triggered because the prior `mise exec -- npm install -g tree-sitter-cli` couldn't actually use mise's node (none managed on EL7); CentOS 7's `clang-devel` is split and the cargo+bindgen build fails to link libclang at runtime. |
| 2 | `coding_agents : Install GitHub Copilot CLI via mise npm` | `EACCES /usr/lib/node_modules/@githubnext` | `mise exec -- npm` falls back to **system** node v16.20.2, which writes to root-owned `/usr/lib`. |
| 3 | same for `Codex CLI` | same `EACCES /usr/lib/node_modules/@openai` | same |
| 4 | same for `Gemini CLI` | same `EACCES /usr/lib/node_modules/@google` (+ EBADENGINE warnings — needs node ≥20) | same |
| 5 | same for `OpenChamber` | same `EACCES /usr/lib/node_modules/@openchamber` | same |
| 6 | `rust_cargo_tools : Install Rust via mise` | `could not download nonexistent rust version 1.95.0 … 404` from `mirrors.tuna.tsinghua.edu.cn/rustup` | TUNA mirror has GC'd / not yet pulled rust 1.95.0; `~/.cargo/config.toml` redirects rustup there. |

**All six are solvable.** They share one upstream cause: [`dot_config/mise/config.toml.tmpl`](../../dot_config/mise/config.toml.tmpl) (lines 8-19, 30-43) intentionally **omits `node` and `rust`** from mise's `[tools]` on CentOS 7 (glibc 2.17 baseline, TUNA mirror gap), but the ansible roles don't know that and blindly call `mise exec -- npm …` / `mise install rust@latest`.

The mise config-file comment block (lines 33-37) already documents the manual fallbacks:

- Node.js: NodeSource RPM (skipped here per user choice — EL7 ships node 16 only, too old for the agents anyway).
- Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`.

This plan codifies those fallbacks in ansible so a fresh `chezmoi apply` on EL7 stops failing.

## User-confirmed decisions

- **Node-based CLIs on EL7** → **skip cleanly** (don't try system node 16 with `--prefix ~/.local`; node <20 breaks most of them at runtime anyway).
- **Rust on EL7** → **skip mise's rust install, run `rustup-init` directly** (the path the mise config comment already prescribes).

## Approach

Single shared `oldEL` fact + per-role guard, mirroring the `$oldEL` template logic in `dot_config/mise/config.toml.tmpl:8-19`. No new pitfall surfaces — extend the existing `pitfalls/centos7-noroot.md` notes and add a one-liner cross-link.

### Step 1 — Define `oldEL` once, in the playbook

File: [`dot_ansible/playbooks/site.yml`](../../dot_ansible/playbooks/site.yml) (or wherever the top-level `pre_tasks:` for Linux lives — verify during execution).

Add a `pre_tasks` (Linux-only) `set_fact` so every role can reference it:

```yaml
- name: Detect CentOS/RHEL 7 (glibc 2.17 baseline) — mirrors mise config.toml.tmpl $oldEL
  ansible.builtin.set_fact:
    oldEL: >-
      {{ ansible_facts['os_family'] == 'RedHat'
         and (ansible_facts['distribution_major_version'] | string) == '7' }}
  when: ansible_facts['os_family'] == 'RedHat'
```

(For non-RedHat hosts `oldEL` stays undefined and the `default(false)` filter in role `when:` clauses keeps it falsy.)

### Step 2 — Gate `rust_cargo_tools` on `oldEL` and add rustup-init fallback

File: [`dot_ansible/roles/rust_cargo_tools/tasks/main.yml:18-23`](../../dot_ansible/roles/rust_cargo_tools/tasks/main.yml).

Replace the single `Install Rust via mise` task with a two-branch pattern:

```yaml
- name: Install Rust via mise (non-EL7)
  when: not (oldEL | default(false))
  ansible.builtin.command: "{{ mise_bin }} install rust@latest"
  args:
    creates: "{{ ansible_facts['env']['HOME'] }}/.local/share/mise/installs/rust"
  environment:
    PATH: "{{ ansible_facts['env']['HOME'] }}/.local/bin:/opt/homebrew/bin:/usr/local/bin:{{ ansible_facts['env']['PATH'] }}"

# CentOS 7 / RHEL 7: mise's rustup channel goes through the TUNA mirror which
# garbage-collects old versions; rust@latest 404s when TUNA hasn't pulled the
# newest release yet. Use upstream rustup-init directly — it respects the
# user's ~/.cargo/config.toml mirror for crates.io but ignores TUNA for the
# toolchain download. Documented in dot_config/mise/config.toml.tmpl:36-37.
- name: Install Rust via rustup-init (CentOS/RHEL 7 fallback)
  when: oldEL | default(false)
  ansible.builtin.shell: |
    set -e
    if [ -x "{{ ansible_facts['env']['HOME'] }}/.cargo/bin/cargo" ]; then
      echo "ALREADY_INSTALLED"
      exit 0
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --no-modify-path
  args:
    executable: /bin/bash
    creates: "{{ ansible_facts['env']['HOME'] }}/.cargo/bin/cargo"
  environment:
    RUSTUP_DIST_SERVER: "https://static.rust-lang.org"
    RUSTUP_UPDATE_ROOT: "https://static.rust-lang.org/rustup"
```

Downstream `cargo install` tasks (lines 29-37, 46-50, etc.) already prepend `~/.cargo/bin` to PATH — they pick up the rustup-installed cargo without further changes.

### Step 3 — Gate node-based CLI installs on `oldEL`

Files (each task adds `not (oldEL | default(false))` to its existing `when:` list — do **not** rewrite the task bodies):

- [`dot_ansible/roles/lazyvim_deps/tasks/main.yml:293-317`](../../dot_ansible/roles/lazyvim_deps/tasks/main.yml) (`Install tree-sitter-cli via mise npm`) → add EL7 skip
- [`dot_ansible/roles/lazyvim_deps/tasks/main.yml:325-338`](../../dot_ansible/roles/lazyvim_deps/tasks/main.yml) (`Install libclang-dev … Debian/Ubuntu`) — **already Debian-only**, leave alone
- [`dot_ansible/roles/lazyvim_deps/tasks/main.yml:342-361`](../../dot_ansible/roles/lazyvim_deps/tasks/main.yml) (`Install clang-devel … RedHat/CentOS`) → add EL7 skip (cargo path won't fire on EL7 either, see next bullet)
- [`dot_ansible/roles/lazyvim_deps/tasks/main.yml:363-379`](../../dot_ansible/roles/lazyvim_deps/tasks/main.yml) (`Install tree-sitter-cli via cargo (fallback)`) → add EL7 skip + emit a `debug:` task right before it explaining "tree-sitter-cli skipped on EL7: no working node, cargo build needs CentOS-7-incompatible libclang setup; install manually if needed"
- [`dot_ansible/roles/coding_agents/tasks/main.yml:156-172`](../../dot_ansible/roles/coding_agents/tasks/main.yml) — Copilot CLI Linux task → add EL7 skip
- [`dot_ansible/roles/coding_agents/tasks/main.yml:223-239`](../../dot_ansible/roles/coding_agents/tasks/main.yml) — Codex CLI Linux fallback → add EL7 skip
- [`dot_ansible/roles/coding_agents/tasks/main.yml:286-302`](../../dot_ansible/roles/coding_agents/tasks/main.yml) — Gemini CLI Linux → add EL7 skip
- [`dot_ansible/roles/coding_agents/tasks/main.yml:1152-1168`](../../dot_ansible/roles/coding_agents/tasks/main.yml) — OpenChamber Linux → add EL7 skip

The `when:` add looks like:

```yaml
when:
  - ansible_facts["os_family"] in ["Debian", "RedHat"]
  - copilot_check.rc != 0
  - not (oldEL | default(false))   # EL7: mise has no node; system node 16 too old (needs ≥20)
```

### Step 4 — Document in pitfalls

Append a section to [`pitfalls/centos7-noroot.md`](../../pitfalls/centos7-noroot.md) (or extend `centos7-idc-slow-broken-installs.md`):

> ### `mise exec -- npm install -g` and `mise install rust@latest` skipped on EL7
>
> On CentOS 7 `dot_config/mise/config.toml.tmpl` omits `node` and `rust` from
> mise's `[tools]` (glibc 2.17 baseline + TUNA rustup-mirror gap, see
> file comment). `mise exec -- npm` therefore falls back to system node 16,
> which (a) tries to write to root-owned `/usr/lib/node_modules` (EACCES) and
> (b) is too old for `@githubnext/github-copilot-cli`, `@openai/codex`,
> `@google/gemini-cli`, `@openchamber/web` (all require node ≥18-20).
>
> Fix in ansible (Nov 2026): roles `lazyvim_deps` and `coding_agents` gate
> their `mise exec -- npm` tasks on `not oldEL`; `rust_cargo_tools` gates the
> mise install on `not oldEL` and runs `curl https://sh.rustup.rs | sh` for
> the EL7 branch. Manual workaround for the missing CLIs: install Node ≥20
> via NodeSource (`curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo
> bash - && sudo yum install -y nodejs`) then run `npm install -g <pkg>`.

### Step 5 — Verification on the EL7 host

```bash
# 1. Pull the fix
chezmoi update --apply --init       # should now finish 0 failed

# 2. Spot-check the rust path
~/.cargo/bin/rustc --version         # should print "rustc 1.x.x (… )"
which cargo                          # ~/.cargo/bin/cargo

# 3. Confirm node-based CLIs are *cleanly skipped* (not partially installed)
ansible-playbook --syntax-check       # no syntax regression
just docker-run-centos7-noroot        # repro container — re-apply, expect 0 failed
```

Cannot test from the macOS dev box; verification must happen on `idc-server104` (or via `just docker-run-centos7-noroot` which mirrors the corporate box).

## Critical files to modify

- `dot_ansible/playbooks/site.yml` — add `oldEL` `set_fact` (one-time)
- `dot_ansible/roles/rust_cargo_tools/tasks/main.yml:18-23` — split into mise + rustup-init branches
- `dot_ansible/roles/lazyvim_deps/tasks/main.yml:293-379` — add `not oldEL` to four `when:` lists
- `dot_ansible/roles/coding_agents/tasks/main.yml:156, 223, 286, 1152` — add `not oldEL` to four `when:` lists
- `pitfalls/centos7-noroot.md` — append "mise EL7 skips" section

## Out of scope (not fixed by this plan)

- The two `chezmoi apply` prompt lines `.config/mise/config.toml has changed since chezmoi last wrote it?` — that's a separate "user hand-edited a chezmoi-managed file" issue. If the user wants drift handling, they hand-fix or `chezmoi apply --force`.
- Adding a `nodesource_node20` ansible role to actually install the CLIs on EL7 — explicitly rejected by user (skip cleanly).
- The `lazyvim_deps : Install mise global tools` task that ran `changed` despite EL7 having no managed tools — that's expected (the task's `creates:` sentinel touched a file even with the empty `[tools]`-on-EL7 branch). Not a bug.
