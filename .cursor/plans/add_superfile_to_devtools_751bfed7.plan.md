---
name: Add superfile to devtools
overview: "Add superfile (terminal file manager, binary name `spf`) to the devtools ansible role: Homebrew on macOS, GitHub release binary on Linux with sudo + user-level `~/.local/bin` fallback."
todos:
  - id: devtools-macos
    content: Add `superfile` to the Homebrew install list in devtools macOS section
    status: completed
  - id: devtools-linux-sudo
    content: "Add superfile Linux tasks: check + sudo block (GitHub release -> /usr/local/bin/spf)"
    status: completed
  - id: devtools-linux-user
    content: Add superfile user-level fallback (GitHub release -> ~/.local/bin/spf)
    status: completed
  - id: update-docs
    content: Update tool comment in devtools, CLAUDE.md devtools tag, and README.md
    status: completed
isProject: false
---

# Add superfile to devtools ansible role

Superfile is available as `brew install superfile` (Homebrew formula) and as GitHub release tarballs from `yorukot/superfile`. The binary is named `spf`.

## Key differences from the yazi pattern

- **Archive format**: `.tar.gz` (not `.zip`), so use `tar` instead of `unzip`/`python3 -m zipfile`
- **Binary name**: `spf` (not `superfile`)
- **Archive structure**: `dist/superfile-linux-v{version}-{arch}/spf` inside the tarball
- **Arch naming**: GitHub releases use `amd64`/`arm64` (need to map from `target_architecture` which can be `x86_64`/`aarch64`)
- **No armv7l support**: skip on 32-bit ARM (same as yazi)

## Changes

### 1. [dot_ansible/roles/devtools/tasks/main.yml](dot_ansible/roles/devtools/tasks/main.yml)

- Add `superfile` to the macOS Homebrew install list (line ~30, next to `yazi`)
- Add Linux tasks right after the yazi section (~line 1177), following the same 3-block pattern:
  1. **Check**: `spf --version`
  2. **Sudo block**: fetch latest release from GitHub API, download tarball, `tar xzf`, copy `spf` to `/usr/local/bin/spf`
  3. **User-level fallback**: re-check `command -v spf`, same download but extract and copy to `~/.local/bin/spf`
- Architecture mapping: `set_fact` to convert `x86_64` -> `amd64`, `aarch64` -> `arm64` for the download URL
- Update the tools comment on line 3 to include `superfile`

### 2. [CLAUDE.md](CLAUDE.md)

- Add `superfile` to the `devtools` tag description (line 131)

### 3. [README.md](README.md)

- Add `superfile` to the "What You Get > Tools" section (if applicable)

### 4. [run_onchange_after_20_ansible_roles.sh.tmpl](run_onchange_after_20_ansible_roles.sh.tmpl)

- No new hash line needed since superfile is added *within* the existing devtools role (the devtools hash already covers `tasks/main.yml`)

## Download URL pattern

```
https://github.com/yorukot/superfile/releases/download/v{version}/superfile-linux-v{version}-{arch}.tar.gz
```

where `{arch}` is `amd64` or `arm64` and `{version}` comes from the GitHub latest release `tag_name` (stripped of `v` prefix).

## Tarball inner path

```
dist/superfile-linux-v{version}-{arch}/spf
```
