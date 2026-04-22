<!-- ec7b2cd5-ce23-46fe-9db1-407faa223324 -->
---
todos:
  - id: "fd-musl"
    content: "Switch fd user fallback target to musl (x86_64/aarch64/armhf) in dot_ansible/roles/base/tasks/main.yml"
    status: pending
  - id: "yazi-musl-sudo"
    content: "Convert yazi sudo path to direct musl .deb install (drop unzip dependency)"
    status: pending
  - id: "yazi-musl-norote"
    content: "Switch yazi noRoot path to musl .zip and update extraction glob"
    status: pending
  - id: "delta-x86-musl"
    content: "Switch git-delta x86_64 to musl .deb (sudo) and musl tarball (noRoot)"
    status: pending
  - id: "delta-arm64-brew"
    content: "Add brew-or-skip branch for git-delta on aarch64 (no upstream musl)"
    status: pending
  - id: "eza-x86-musl"
    content: "Switch eza user fallback x86_64 to musl tarball"
    status: pending
  - id: "eza-arm64-brew"
    content: "Add brew-or-skip branch for eza on aarch64 (no upstream musl)"
    status: pending
  - id: "tv-brew-or-skip"
    content: "Rewrite television install to brew-or-skip for all arches (no upstream musl)"
    status: pending
  - id: "trippy-sudo-musl"
    content: "Flip trippy system-level download URL from gnu target to musl target"
    status: pending
  - id: "docs-linux-sources"
    content: "Update docs/linux-package-sources.md with glibc-compat policy + Ubuntu 22.04 example"
    status: pending
  - id: "docs-sesh"
    content: "Update docs/tools/sesh.md television install note"
    status: pending
  - id: "validate"
    content: "Run just ansible-syntax-check and chezmoi apply --dry-run; note why docker-test was skipped"
    status: pending
isProject: false
---
## Ubuntu 22.04 glibc Compatibility Hardening

### Root cause

Ubuntu 22.04 LTS ships glibc 2.35. Several Rust tools publish `unknown-linux-gnu` release tarballs built on newer CI images (Ubuntu 24.04 / Debian 13) that link against glibc 2.38+. The user's concrete failure is `tv` needing `GLIBC_2.39`. The same risk exists for other tools in the repo that currently grab `unknown-linux-gnu` binaries.

### Per-tool strategy (verified against latest upstream releases)

Legend: `musl` = switch the asset to the `unknown-linux-musl` variant; `brew` = use Linuxbrew when present; `skip` = print explicit debug message naming the Jammy/glibc incompatibility.

- television (`tv`) — upstream ships **no musl asset** on any arch in 0.15.6. Every arch falls back to `brew -> skip`.
- yazi — musl `.deb` + `.zip` exist for x86_64 and aarch64 → `musl` everywhere.
- fd — musl tarballs exist for x86_64, aarch64, armhf → `musl` everywhere.
- git-delta — musl `.deb` + tarball exist for x86_64 only → `musl` on x86_64, `brew -> skip` on aarch64.
- eza — musl tarball exists for x86_64 only → `musl` on x86_64, `brew -> skip` on aarch64 (user-level fallback only; sudo path is `deb.gierens.de` apt repo and stays untouched).
- trippy — musl targets already present for all supported arches; system-level path currently uses gnu → flip to `{{ trippy_musl_target }}` for parity with the user fallback.

### File changes

#### 1. `dot_ansible/roles/base/tasks/main.yml` — fd fallback

Change the `fd_target` fact (lines 150–159) from gnu to musl triples:

```yaml
fd_target: >-
  {{
    target_architecture ~ '-unknown-linux-musl'
    if target_architecture in ['x86_64', 'aarch64']
    else 'arm-unknown-linux-musleabihf'
    if target_architecture in ['armv7l', 'armhf']
    else ''
  }}
```

All references to `{{ fd_target }}` downstream are already interpolated into filenames, so no further edits needed.

#### 2. `dot_ansible/roles/devtools/tasks/main.yml`

**yazi — sudo path (lines 1490–1548):** replace the download-`.zip` + `unzip` + manual copy chain with a direct musl `.deb` install:

- URL: `yazi-{{ target_architecture }}-unknown-linux-musl.deb` → `/tmp/yazi.deb`
- Install via `ansible.builtin.apt: deb: /tmp/yazi.deb`
- Drop the `apt install unzip` task and the `unzip`/`cp` shell block

**yazi — noRoot path (lines 1558–1616):** change the URL from `…-unknown-linux-gnu.zip` to `…-unknown-linux-musl.zip`, and update the two glob occurrences `yazi-*-unknown-linux-*` to match the musl directory that the zip unpacks into. Keep `python3 -m zipfile` logic.

**git-delta — sudo path (lines 638–696):** split by arch:
- x86_64 / amd64: `git-delta-musl_{{ version }}_amd64.deb` → apt deb install.
- aarch64 / arm64: probe brew (mirror the tmux-upgrade pattern at lines 1824–1843); use `community.general.homebrew: name: git-delta` if present; otherwise a `debug:` task noting "no musl asset upstream; install Linuxbrew or wait for upstream musl `.deb`".

**git-delta — user path (lines 698–764):** same split:
- x86_64: `delta-{{ version }}-x86_64-unknown-linux-musl.tar.gz` (folder name inside tarball also changes to `-musl`, update the `copy: src:` path).
- aarch64: probe brew → install via homebrew module; otherwise skip/warn. (brew's `/home/linuxbrew/.linuxbrew/bin` is typically on PATH; no manual symlink to `~/.local/bin` needed.)

**eza — user fallback (lines 580–636):**
- x86_64: switch URL from `eza_x86_64-unknown-linux-gnu.tar.gz` → `eza_x86_64-unknown-linux-musl.tar.gz`.
- aarch64: probe brew → `community.general.homebrew: name: eza`; else skip/warn.

Tighten the `when:` guard on the GitHub-release block so aarch64 only runs under the brew-present branch; today the whole block runs for both arches.

**television — user install (lines 2368–2487):** full rewrite because no musl asset exists:
- Keep the `tv_check` probe.
- Add Linuxbrew probe (`command -v brew`).
- If brew present: `community.general.homebrew: name: television`.
- Else: single `debug:` task — "tv skipped: upstream publishes only `unknown-linux-gnu` which requires glibc ≥ 2.39 (Jammy ships 2.35). Install Linuxbrew or wait for upstream musl builds."
- Delete the entire `Get latest television release` → `Clean up television temp files` block.
- Keep the trailing `tv update-channels` task guarded by `command -v tv`.

#### 3. `dot_ansible/roles/networking_tools/tasks/main.yml` — trippy system path

Single-line fix in the task at line 289:

```yaml
url: "https://github.com/fujiapple852/trippy/releases/download/{{ trippy_release.json.tag_name }}/trippy-{{ trippy_release.json.tag_name }}-{{ trippy_musl_target }}.tar.gz"
```

`trippy_musl_target` is already defined at lines 258–264 and covers x86_64, aarch64, armv7. The `trippy_gnu_target` fact becomes unused but is kept in place (it's cheap and documents the arch table).

#### 4. `docs/linux-package-sources.md`

Add a new short section after "Example: tmux" titled **"Example: glibc compatibility on Ubuntu 22.04"** explaining:
- Jammy ships glibc 2.35; many Rust/Go binaries now ship `unknown-linux-gnu` built on Ubuntu 24.04 CI (glibc 2.38+) and fail with `GLIBC_2.X not found`.
- Policy: prefer `unknown-linux-musl` assets when upstream provides them; fall back to Linuxbrew (when available) for arches lacking musl; skip-with-warning instead of silently installing a potentially incompatible gnu binary.
- Reference the concrete case that triggered this (television).

Update the "Linux with sudo" / "Linux noRoot" block in "Repo policy" so the GitHub-binary step explicitly notes "prefer musl".

#### 5. `docs/tools/sesh.md`

Update line 194 so the Television install note no longer claims a GitHub release is always used on Linux:

> Television is installed by the `devtools` ansible role (`brew install television` on macOS; Linuxbrew on Linux when available, otherwise skipped because upstream currently ships only `unknown-linux-gnu` binaries that require glibc ≥ 2.39).

### Reuse of existing patterns

All new "probe brew → install or skip" blocks follow the tmux-upgrade precedent already established in devtools/tasks/main.yml (lines 1813–1951). Musl-asset selection mirrors ripgrep (base role), bat / zellij / btop / tailspin / lnav (devtools), and trippy user fallback (networking_tools).

### Validation

After implementation:
- `just ansible-syntax-check` — ansible syntax check for base.yml / macos.yml / linux.yml (this is the `ansible-playbook --syntax-check` batch from CLAUDE.md).
- `chezmoi apply --dry-run` — confirm no templating regressions.
- `just docker-test` (Ubuntu container smoke test) is likely **skipped** because the container layer image is `ubuntu:latest`, not `22.04`, and rebuilding the smoke image just to exercise this codepath is disproportionate for a surgical patch. Will call this out explicitly in the summary.

### Out of scope (verified, left alone)

- sesh: Go binary, no `-gnu`/`-musl` suffix upstream, no known glibc issue.
- doggo: Go binary, same reasoning.
- gping: already uses `gping-Linux-musl-<arch>.tar.gz`.
- btop, zellij, bat, tailspin, lnav, bandwhich: already on musl.
- `.deb` packages installed via apt that come from vendor apt repos (`eza` via `deb.gierens.de`, `gh`, `glab`, `docker.io`) are built for the target distro and aren't affected.
- `tlrc`, Go tools (Ookla speedtest), duckdb, diffnav, superfile: distribute per-OS binaries that do not have a gnu/musl distinction in their filenames.

### Remaining arm64 gaps (to call out in final summary)

Even after the patch, users running `aarch64` Ubuntu 22.04 **without** Linuxbrew will still have gaps for:
- television (no upstream musl, any arch)
- git-delta (no aarch64 musl)
- eza (no aarch64 musl)

These will print the new skip-warning messages instead of silently installing gnu binaries that may break. Users can install Linuxbrew to close the gap, or wait for upstream to ship musl assets.
