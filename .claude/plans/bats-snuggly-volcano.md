# Add bats-core to devtools role

## Context

Add [bats-core](https://github.com/bats-core/bats-core) — the standard Bash testing framework — as a devtool across all supported platforms. Bats is pure-bash, portable, and arch-agnostic (so no `armv7l` skip logic needed). This mirrors how other shell-adjacent tools are installed in the `devtools` role and makes `bats` available for testing shell scripts in this repo and beyond.

Scope intentionally excludes `bats-support` / `bats-assert` / `bats-file` helper libraries — those are project-local (vendored per-repo as submodules), not system-wide.

## Install strategy

| Platform | Method | Notes |
|---|---|---|
| macOS | Homebrew formula `bats-core` | Append to existing `homebrew` task list |
| Linux (sudo) | `apt install bats` | Ubuntu 20.04+ has a `bats` package |
| Linux (noRoot) | GitHub release tarball + `./install.sh ~/.local` | Pure-bash, no arch matrix needed |

The GitHub-release fallback uses the official `install.sh` script inside the tarball, which places `bats` in `$PREFIX/bin` and libraries in `$PREFIX/lib/bats-core` / `$PREFIX/libexec/bats-core`. That matches how `~/.local` is already used across the role.

## Files to modify

### 1. `dot_ansible/roles/devtools/tasks/main.yml`

**Header comment (line 3)** — add `bats` to the tools list.

**macOS block (line 15-43)** — insert `bats-core` into the alphabetical-ish list; place near `coreutils`/`taplo` or at end of list:
```yaml
- bats-core
```

**Linux block** — add a new `# --- bats ---` section. Follow the exact pattern used by `bat` (lines 337-421): short apt install (with `tags: [sudo]` and `become: true`), followed by a user-level fallback that checks `command -v bats` and falls back to the GitHub tarball. Skeleton:

```yaml
# --- bats ---
- name: Install bats (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name: bats
    state: present

# --- bats (user-level fallback) ---
- name: Re-check if bats is installed
  when: ansible_facts["os_family"] == "Debian"
  ansible.builtin.shell: command -v bats
  register: bats_recheck
  changed_when: false
  failed_when: false
  environment:
    PATH: "{{ ansible_facts['env']['HOME'] }}/.local/bin:/usr/local/bin:{{ ansible_facts['env']['PATH'] }}"

- name: Install bats-core from GitHub releases (user-level, no sudo)
  when:
    - ansible_facts["os_family"] == "Debian"
    - bats_recheck.rc != 0
  block:
    - name: Ensure ~/.local/bin exists (bats)
      ansible.builtin.file:
        path: "{{ ansible_facts['env']['HOME'] }}/.local/bin"
        state: directory
        mode: '0755'

    - name: Get latest bats-core release
      ansible.builtin.uri:
        url: https://api.github.com/repos/bats-core/bats-core/releases/latest
        return_content: true
      register: bats_release

    - name: Download bats-core tarball
      ansible.builtin.get_url:
        url: "https://github.com/bats-core/bats-core/archive/refs/tags/{{ bats_release.json.tag_name }}.tar.gz"
        dest: /tmp/bats.tar.gz
        mode: '0644'
        timeout: 120
      retries: 3
      delay: 5

    - name: Extract and install bats-core to ~/.local
      ansible.builtin.shell: |
        set -euo pipefail
        rm -rf /tmp/bats-extract
        mkdir -p /tmp/bats-extract
        tar -xzf /tmp/bats.tar.gz -C /tmp/bats-extract --strip-components=1
        /tmp/bats-extract/install.sh "{{ ansible_facts['env']['HOME'] }}/.local"
      args:
        executable: /bin/bash
      changed_when: true

    - name: Clean up bats temp files
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - /tmp/bats.tar.gz
        - /tmp/bats-extract

  rescue:
    - name: Warn bats-core installation failed
      ansible.builtin.debug:
        msg: "bats-core installation failed (likely network timeout) - skipping"

    - name: Clean up bats temp files after failure
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - /tmp/bats.tar.gz
        - /tmp/bats-extract
```

Placement: insert the block right after the `bat` section (after line ~421) so shell-adjacent tools sit together.

### 2. `README.md`

- Line 177 (Bootstrap devtools list) — append `bats` to the comma list.
- Section `### Tools (via ansible)` (lines 154-171) — add a new bullet:
  `- **Shell testing**: \`bats\` (bats-core) — Bash test runner with TAP/JUnit output`

### 3. `CLAUDE.md`

- `devtools` tag row in the "Available Tags" table (line ~111) — append `, bats` to the tool list.
- "No Root Mode > User-level tools > GitHub binaries" list (line ~175) — append `, bats`.
- "ARM / Raspberry Pi Support > Tools with armv7l/armhf releases" list — append `bats` (pure-bash so all architectures work, including armv7l).

## Critical files to reuse / mirror

- `/home/ldw/.local/share/chezmoi/dot_ansible/roles/devtools/tasks/main.yml:337-421` — `bat` pattern (apt + user-level GitHub fallback). Use as the template for the new `bats` block.
- `/home/ldw/.local/share/chezmoi/dot_ansible/roles/devtools/tasks/main.yml:18-42` — macOS homebrew list.

## Verification

```bash
# 1. Syntax check (from repo root)
ANSIBLE_CONFIG=dot_ansible/ansible.cfg \
  ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg \
  ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml

# 2. Docker dry-run to confirm apt install path
just docker-test

# 3. Local smoke test after `chezmoi apply`
bats --version   # should print bats 1.x.y
# quick sanity test
cat > /tmp/hello.bats <<'EOF'
@test "addition" { result="$(( 2 + 2 ))"; [ "$result" -eq 4 ]; }
EOF
bats /tmp/hello.bats
```

## Non-goals

- Not installing `bats-support` / `bats-assert` / `bats-file` — those belong per-project (git submodule under `test/test_helper/`).
- Not adding `shellcheck` / `shfmt` — out of scope for this request (would be a follow-up).
