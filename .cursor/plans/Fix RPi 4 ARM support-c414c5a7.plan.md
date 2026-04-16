<!-- c414c5a7-9439-4b84-9b8a-f30c5fd33176 -->
---
todos:
  - id: "bootstrap-linuxbrew"
    content: "Skip Linuxbrew installation on non-amd64/arm64 userland architectures in bootstrap script"
    status: pending
  - id: "bootstrap-mise-arch"
    content: "Fix hardcoded arch=amd64 in mise apt fallback to use dpkg --print-architecture"
    status: pending
  - id: "ansible-arch-detection"
    content: "Add pre_tasks to linux.yml to detect real userland architecture and override ansible_architecture"
    status: pending
  - id: "audit-roles-arch"
    content: "Audit ansible roles for architecture-specific downloads and add graceful armv7l/armhf handling"
    status: pending
  - id: "update-docs"
    content: "Update CLAUDE.md/README.md with Raspberry Pi / ARM architecture notes"
    status: pending
isProject: false
---
# Fix Raspberry Pi 4 ARM Architecture Mismatch

## Root Cause

Raspberry Pi 4 runs 32-bit Raspberry Pi OS (`armhf` userland) with a 64-bit kernel (`arm_64bit=1` default). This causes:
- `uname -m` -> `aarch64` (kernel arch)
- `dpkg --print-architecture` -> `armhf` (userland arch)
- Homebrew installer detects `aarch64`, downloads 64-bit Portable Ruby, which can't run on 32-bit userland

RPi 5 works because it only supports 64-bit OS where both kernel and userland are `aarch64`/`arm64`.

## Fix 1: Bootstrap Script (Critical - blocks everything)

**File**: `run_once_before_00_bootstrap.sh.tmpl`

### 1a. Skip Linuxbrew on incompatible architectures

Before the Linuxbrew install block (line 80-98), detect the real userland architecture:

```bash
# Detect userland architecture (kernel may differ, e.g. RPi 4: armhf userland + aarch64 kernel)
if command -v dpkg &>/dev/null; then
    REAL_ARCH="$(dpkg --print-architecture)"
else
    REAL_ARCH="$(uname -m)"
fi

case "$REAL_ARCH" in
    amd64|x86_64|arm64|aarch64)
        # Supported by Homebrew on Linux - proceed
        ;;
    *)
        warn "Skipping Linuxbrew: unsupported userland architecture '$REAL_ARCH' (Homebrew requires amd64 or arm64)"
        # Skip to next section
        ;;
esac
```

### 1b. Fix mise apt fallback hardcoded `arch=amd64`

Line 126 hardcodes `arch=amd64`. Change to detect dynamically:

```bash
echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.pub arch=$(dpkg --print-architecture)] https://mise.jdx.dev/deb stable main"
```

Note: mise's deb repo may only have amd64 packages, so this would fail cleanly on ARM rather than adding a broken repo.

## Fix 2: Ansible Architecture Detection (Important)

**File**: `dot_ansible/playbooks/linux.yml`

Add `pre_tasks` to detect and override architecture for correct binary downloads:

```yaml
pre_tasks:
  - name: Detect userland architecture (handles 32-bit userland on 64-bit kernel)
    ansible.builtin.command: dpkg --print-architecture
    register: dpkg_arch_result
    changed_when: false
    when: ansible_facts["os_family"] == "Debian"

  - name: Map dpkg architecture to uname-style values
    ansible.builtin.set_fact:
      real_userland_arch: >-
        {{ {'amd64': 'x86_64', 'arm64': 'aarch64', 'armhf': 'armv7l', 'armel': 'armv6l', 'i386': 'i686'}
           [dpkg_arch_result.stdout | default('unknown')]
           | default(ansible_facts['architecture']) }}
    when: dpkg_arch_result is defined and dpkg_arch_result.rc == 0
```

Then update roles to use `real_userland_arch | default(ansible_facts['architecture'])` instead of `ansible_facts['architecture']` for download URLs. Alternatively, override `ansible_architecture` directly so existing roles work without changes:

```yaml
  - name: Override architecture fact to match userland
    ansible.builtin.set_fact:
      ansible_architecture: "{{ real_userland_arch }}"
    when: real_userland_arch is defined and real_userland_arch != ansible_facts['architecture']
```

This is the cleanest approach -- all existing `ansible_facts['architecture']` references in roles would automatically use the corrected value.

## Fix 3: Graceful Failures for Unsupported Architectures

Many GitHub release downloads only provide `x86_64` and `aarch64` binaries. On `armv7l`, these downloads will 404. The existing roles handle this in various ways:

- Some already check architecture (e.g., `git-graph` checks `x86_64` only)
- Some have `ignore_errors: true`
- Some will fail hard

For roles that download binaries with hardcoded arch assumptions, ensure they skip gracefully on armv7l. Key roles to audit:
- `base/tasks/main.yml` - ripgrep, fd, jq, just (ripgrep/fd have armv7l musl builds)
- `devtools/tasks/main.yml` - many tools (bat, eza, delta, yazi, zellij, sesh, taplo, tv, etc.)
- `neovim/tasks/main.yml` - neovim GitHub release
- `lazyvim_deps/tasks/main.yml` - fzf, lazygit, tree-sitter
- `security_tools/tasks/main.yml` - gitleaks

## Files to Modify

1. `run_once_before_00_bootstrap.sh.tmpl` - skip Linuxbrew on armhf, fix mise arch
2. `dot_ansible/playbooks/linux.yml` - add pre_tasks for arch detection
3. Various ansible roles - audit and add arch guards where missing (many will need `armv7l` added to skip conditions)

## Impact

- RPi 4 (32-bit OS): bootstrap completes, apt-based tools install, GitHub-release tools skip gracefully if no armhf build
- RPi 5 (64-bit OS): no change, everything works as before
- x86_64 Linux: no change
