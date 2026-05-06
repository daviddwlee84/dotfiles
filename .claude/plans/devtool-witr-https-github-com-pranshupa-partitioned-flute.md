# Add witr to devtools role

## Context

User wants to install [witr](https://github.com/pranshuparmar/witr) ("Why Is This Running?") — a Go-based process diagnostic tool that traces process ancestry, supervision hierarchies, resolves ports to processes, and provides a TUI dashboard. It fills the gap between `ps`/`top` and a full explanation of *why* something is running.

It fits alongside `btop`/`htop` in the devtools role (process monitoring category).

## What witr provides

- Traces process ancestry chains and supervision hierarchies
- Resolves ports → processes → origin explanation
- Real-time TUI dashboard (`witr`)
- Multiple output formats (standard, tree, JSON, env vars)
- Written in Go; v0.3.1 released 2026-03-18

## Files to modify

### 1. `dot_ansible/roles/devtools/tasks/main.yml`

**Line 3** — update the `# Tools:` header comment to include `witr`:
```
# Tools: bat, bats, gh, glab, ... btop, htop, duckdb, rclone, coreutils, taplo, television, pandoc, tailspin, lnav, grc, ccze (Linux only), dasel, yq, jnv, witr
```

**macOS Homebrew list** (after `jnv` on line ~54) — add one entry:
```yaml
      - witr
```

**End of file** (after `jnv` block at line 3592) — add a new Linux section:

```yaml
# --- witr (Why Is This Running? — process ancestry / supervision tracer) ---
- name: Re-check if witr is installed
  when: ansible_facts["os_family"] == "Debian"
  ansible.builtin.shell: command -v witr
  register: witr_check
  changed_when: false
  failed_when: false

- name: Set witr release architecture
  when:
    - ansible_facts["os_family"] == "Debian"
    - witr_check.rc != 0
  ansible.builtin.set_fact:
    witr_arch: >-
      {{
        'amd64' if target_architecture in ['x86_64', 'amd64']
        else 'arm64' if target_architecture in ['aarch64', 'arm64']
        else ''
      }}

- name: Install witr from GitHub releases (user-level, no sudo)
  when:
    - ansible_facts["os_family"] == "Debian"
    - witr_check.rc != 0
    - witr_arch | default('') != ''
  block:
    - name: Ensure ~/.local/bin exists (witr)
      ansible.builtin.file:
        path: "{{ ansible_facts['env']['HOME'] }}/.local/bin"
        state: directory
        mode: '0755'

    - name: Download witr binary
      ansible.builtin.get_url:
        url: "https://github.com/pranshuparmar/witr/releases/latest/download/witr-linux-{{ witr_arch }}"
        dest: "{{ ansible_facts['env']['HOME'] }}/.local/bin/witr"
        mode: '0755'
        timeout: 120
      retries: 3
      delay: 5

  rescue:
    - name: Warn witr installation failed
      ansible.builtin.debug:
        msg: "witr installation failed (likely network timeout or unsupported arch) - skipping"

    - name: Clean up witr temp files after failure
      ansible.builtin.file:
        path: "{{ ansible_facts['env']['HOME'] }}/.local/bin/witr"
        state: absent
```

**Pattern rationale**: witr ships direct binaries (`witr-linux-amd64`, `witr-linux-arm64`) — no tarball/archive needed, so the simpler `dasel`/`yq` direct-download pattern is appropriate rather than the extract-then-install pattern used for tools like `jnv` or `worktrunk`.

### 2. `README.md`

**Line 241** — append `witr` to the Dev tools list:
```
- **Dev tools**: bat, bats, gh, glab, diffnav, git-delta, git-graph, eza, tldr, [glow](docs/tools/glow.md), [gum](docs/tools/gum.md), [vhs](docs/tools/vhs.md), [freeze](docs/tools/freeze.md), thefuck, zoxide, direnv, yazi, superfile, tmux+tpm, sesh, worktrunk ([workflow playbook](docs/tools/worktrunk.md)), zellij, btop, htop, taplo, television, pandoc, witr
```

## What does NOT need updating

- `scripts/upgrade_tools.sh`: macOS handled by `brew upgrade` (automatic). Linux GitHub-release tools have no explicit upgrade mechanism in the current script — consistent with dasel, yq, jnv, etc. witr has no self-update subcommand.
- `docs/zsh/aliases.md`: no new aliases or shell functions added.
- No new `docs/` pages needed.

## Verification

After implementing:
```bash
# macOS
brew install witr
witr --version

# Linux (via ansible)
chezmoi apply  # runs ansible devtools role
witr --version
witr  # launches TUI
```
