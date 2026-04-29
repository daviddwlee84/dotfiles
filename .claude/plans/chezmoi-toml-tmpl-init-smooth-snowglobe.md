# Add `installMediaTools` 影音包 to chezmoi init

## Context

This repo's `.chezmoi.toml.tmpl` currently exposes ~15 opt-in feature bundles
(coding agents, networking, IaC, .NET, etc.) but has no first-class story for
**audio/video/image processing** CLI tools. ffmpeg specifically is a
documented gap — `dot_ansible/roles/devtools/tasks/main.yml:1450` says VHS
needs `ffmpeg` at runtime but does not auto-install it ("heavy and opt-in;
see docs/tools/vhs.md"). Users who want vhs to actually record have to
`brew install ffmpeg` / `apt install ffmpeg` by hand on every host, and the
sibling tools (ImageMagick, exiftool, libvips) have no entry point at all.

This change introduces a single new init prompt — `installMediaTools` — that
bundles **ffmpeg + ImageMagick + exiftool + libvips** under one toggle, plumbed
through the established `installNetworkingTools` / `installIacTools` pattern so
parity with `Dockerfile`, `dotfiles_init.py`, and the ansible role-tag
selector is preserved (the `doctor` subcommand will lint this).

User confirmations (asked at plan time):

- **Tool scope**: all four — ffmpeg, ImageMagick, exiftool, libvips.
- **Docs scope**: include in same change — 4 × bilingual pairs
  (English + zh-TW) wired into `mkdocs.yml` nav and nav_translations.
- **Aliases**: include three zsh helper functions (`compress-video`,
  `extract-audio`, `to-wav16k`) under a new `dot_config/zsh/tools/29_media.zsh`,
  with the corresponding row in `docs/zsh/aliases.md` per the
  CLAUDE.md "Custom aliases" mirror rule.

Naming locked in:

| Surface | Value |
|---|---|
| chezmoi prompt key | `installMediaTools` |
| Prompt text (shown by `chezmoi init`) | `Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)` |
| Ansible role / tag | `media_tools` |
| Dockerfile ARG | `CHEZMOI_INSTALL_MEDIA_TOOLS` |
| zsh helpers file | `dot_config/zsh/tools/29_media.zsh` (slot is free between `28_tldr.zsh` and `30_direnv.zsh`) |
| Docs filenames | `docs/tools/{ffmpeg,imagemagick,exiftool,libvips}.md` + `*.zh-TW.md` siblings |

---

## Files changed

### 1. `.chezmoi.toml.tmpl` — add prompt

Insert after `installIacTools` (line 70) so the new prompt sits next to its
sibling install-bundle prompts (the surrounding lines 67-72 are all
`installXxxTools` style):

```toml
# 是否安裝影音/媒體 CLI 工具 (ffmpeg, ImageMagick, exiftool, libvips)
# ffmpeg 也是 vhs 的 runtime 依賴，裝了 vhs 才能真正錄製。詳見 docs/tools/ffmpeg.md
installMediaTools = {{ promptBoolOnce . "installMediaTools" "Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)" false }}
```

Default `false`. Personal-mac users will get it via the `personal-mac` bundle
override below; everyone else opts in explicitly.

### 2. `Dockerfile` — ARG + `--promptBool` flag

Add `ARG CHEZMOI_INSTALL_MEDIA_TOOLS=false` after line 22 (next to
`CHEZMOI_INSTALL_IAC_TOOLS`).

Add a matching `--promptBool` line after line 137 (matching prompt text
**byte-exact** — `chezmoi init` matches by text, not key):

```dockerfile
    --promptBool "Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)=${CHEZMOI_INSTALL_MEDIA_TOOLS}" \
```

### 3. `scripts/init/dotfiles_init.py`

Add a `Prompt(...)` entry to the `PROMPTS` tuple (insert in the **Dev tooling**
group after `installIacTools` at line 171, since these are dev-tooling
adjacent CLIs, not "System & apps"):

```python
    Prompt("installMediaTools", "bool", "Dev tooling",
           "Media / AV CLI tools",
           "ffmpeg, ImageMagick, exiftool, libvips. ffmpeg is also vhs's runtime dep.",
           default=False,
           prompt_text="Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)"),
```

`prompt_text` MUST match `.chezmoi.toml.tmpl` byte-exact — the
`doctor_scan` regex in `dotfiles_init.py:626` will fail otherwise.

Update `BUNDLES` (line 236-289):

- `personal-mac` — add `"installMediaTools": True` (user runs vhs / does
  media work).
- `work-mac`, `server-linux`, `minimal` — add `"installMediaTools": False`
  to be explicit (`minimal` already enumerates every flag explicitly per its
  comment at line 264).

### 4. NEW `dot_ansible/roles/media_tools/tasks/main.yml`

Mirror the structure of `dot_ansible/roles/networking_tools/tasks/main.yml`
(macOS Homebrew block first, then Linux apt block gated by `become: true` +
`tags: [sudo]`). All four tools have first-class apt + brew packages, so we
don't need the GitHub-release / user-level fallback ladder that
networking_tools / iac_tools use.

```yaml
---
# Media / AV CLI tools role
# Tools: ffmpeg, ImageMagick (magick), exiftool, libvips (vips/vipsthumbnail)
# ffmpeg is also vhs's runtime dependency — see dot_ansible/roles/devtools/
# tasks/main.yml `# --- vhs ---` block.

# =============================================================================
# macOS — all via Homebrew
# =============================================================================

- name: Install media/AV tools (macOS)
  when: ansible_facts["os_family"] == "Darwin"
  community.general.homebrew:
    name:
      - ffmpeg        # provides ffmpeg, ffprobe, ffplay
      - imagemagick   # provides magick (and convert/identify shims)
      - exiftool
      - vips          # provides vips, vipsthumbnail, vipsedit
    state: present

# =============================================================================
# Linux (Debian/Ubuntu) — apt
# =============================================================================

- name: Install media/AV tools from apt (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name:
      - ffmpeg                       # ffmpeg + ffprobe; ffplay separate via ffmpeg suggests
      - imagemagick                  # magick (>=7) or convert (legacy)
      - libimage-exiftool-perl       # provides /usr/bin/exiftool
      - libvips-tools                # vips, vipsthumbnail, vipsedit
    state: present
    update_cache: true
```

Notes:

- No `defaults/main.yml` needed — no role-level toggles (matches
  `networking_tools` which also has none).
- `noRoot=true` Linux users are handled by the upstream `--skip-tags sudo`
  injection in `run_onchange_after_20_ansible_roles.sh.tmpl:258`. Since the
  Linux block has `tags: [sudo]`, it gets skipped automatically — no extra
  conditional needed in this role. Document this in the role's task
  comment so future maintainers don't add a redundant `not noRoot` guard.
- ImageMagick on Ubuntu 24.04 ships v6 by default
  (`/usr/bin/convert`); v7 ships the unified `magick` binary. The package
  name is the same; just note in docs that `convert`/`magick` may differ.

### 5. `dot_ansible/playbooks/linux.yml` + `macos.yml`

Add the role entry. Place after `iac_tools` to keep the install-bundle
roles clustered:

**`linux.yml`** — insert after line 95 (after the `iac_tools` block):

```yaml
    - role: media_tools
      tags: [media_tools]
```

**`macos.yml`** — insert after line 76 (after the `iac_tools` block):

```yaml
    - role: media_tools
      tags: [media_tools]
```

### 6. `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`

Two surgical edits:

**(a) Role hash comment** (so the run_onchange script re-fires when the role
changes — append after the `iac_tools defaults` line at line 37):

```bash
# media_tools: {{ include "dot_ansible/roles/media_tools/tasks/main.yml" | sha256sum }}
```

**(b) Conditional tag injection** (mirrors lines 165-168 — add after the
`iac_tools` block, before `dotnet_tools`):

```bash
{{ $installMediaTools := false }}{{ if hasKey . "installMediaTools" }}{{ $installMediaTools = .installMediaTools }}{{ end -}}
{{ if $installMediaTools -}}
TAGS="${TAGS},media_tools"
{{ end -}}
```

The `hasKey` guard preserves backwards-compat with existing
`~/.config/chezmoi/chezmoi.toml` files that pre-date this prompt
(consistent with all the other optional flags in this script).

### 7. NEW `dot_config/zsh/tools/29_media.zsh` — three helper functions

```bash
# Media/AV helpers — only loaded when ffmpeg is on $PATH (installMediaTools=true).
# Functions, not aliases, so they accept positional args and do filename derivation.

if (( ${+commands[ffmpeg]} )); then
    # Compress an MP4 with x264 CRF 28 (smaller; tweak CRF inline for quality).
    compress-video() {
        emulate -L zsh
        [[ -f "$1" ]] || { echo "usage: compress-video <input>" >&2; return 2; }
        ffmpeg -i "$1" -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 128k "${1:r}_compressed.mp4"
    }

    # Extract audio without re-encoding (output is .m4a; works for AAC sources).
    extract-audio() {
        emulate -L zsh
        [[ -f "$1" ]] || { echo "usage: extract-audio <input>" >&2; return 2; }
        ffmpeg -i "$1" -vn -c:a copy "${1:r}.m4a"
    }

    # Re-encode to 16 kHz mono WAV — what Whisper / faster-whisper / wav2vec want.
    to-wav16k() {
        emulate -L zsh
        [[ -f "$1" ]] || { echo "usage: to-wav16k <input>" >&2; return 2; }
        ffmpeg -i "$1" -ar 16000 -ac 1 "${1:r}_16k.wav"
    }
fi
```

The `(( ${+commands[ffmpeg]} ))` guard means the file is harmless on hosts
where `installMediaTools=false` — matches the pattern in `26_eza.zsh`,
`20_zoxide.zsh`, etc.

### 8. `docs/zsh/aliases.md` — register the three functions

Add a new H2 section (alphabetically between **Log Viewers** and
**Shell Utilities** — table of contents at line 9-27 also gets the entry):

```markdown
## Media / AV

> Provided by ffmpeg. Functions only loaded when `installMediaTools=true`
> (or `ffmpeg` is otherwise on `$PATH`).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `compress-video` | function | `dot_config/zsh/tools/29_media.zsh` | x264 CRF 28 re-encode → `<name>_compressed.mp4` |
| `extract-audio` | function | `dot_config/zsh/tools/29_media.zsh` | Strip video, copy audio → `<name>.m4a` (no re-encode) |
| `to-wav16k` | function | `dot_config/zsh/tools/29_media.zsh` | Resample to 16 kHz mono WAV → `<name>_16k.wav` (Whisper-ready) |
```

### 9. NEW docs pages — 4 tools × 2 languages = 8 files

Mirror `docs/tools/freeze.md` structure (read it as the canonical template):

```
# <Tool> — <one-liner>
[Intro + GitHub link]
- **Install**: <macOS via Homebrew (managed by media_tools role) / Linux via apt (managed by media_tools role)>
- **Verify**: `<tool> --version`
- **Status in this repo**: bundled under `installMediaTools=true`. Zsh helper(s): … (where applicable).

## <Primary mode>
## <Secondary feature(s)>
## Common flags
## Usage patterns
### <pattern 1>
### <pattern 2>
## See also
```

Files to create:

| English | zh-TW |
|---|---|
| `docs/tools/ffmpeg.md` | `docs/tools/ffmpeg.zh-TW.md` |
| `docs/tools/imagemagick.md` | `docs/tools/imagemagick.zh-TW.md` |
| `docs/tools/exiftool.md` | `docs/tools/exiftool.zh-TW.md` |
| `docs/tools/libvips.md` | `docs/tools/libvips.zh-TW.md` |

Content per page:

- **ffmpeg** — transcode, compression (CRF), audio extraction, GIF, frame
  extraction, screen recording. Cross-link to the new `29_media.zsh`
  functions and to `docs/tools/vhs.md` ("vhs needs ffmpeg as runtime dep
  — installing this bundle satisfies it").
- **imagemagick** — single-image convert, batch resize, JPG quality, PNG→JPG
  with alpha removal, crop. Note the v6 (`convert`) vs v7 (`magick`)
  distinction on Ubuntu 24.04 vs macOS Homebrew.
- **exiftool** — view/strip EXIF, GPS scrubbing, timestamp fix. Pair it
  with the privacy warning from the Freeze page ("don't snapshot secrets").
- **libvips** — `vipsthumbnail` for batch high-res thumbnails, when to
  pick libvips over ImageMagick (memory + speed at scale). Cross-link to
  imagemagick.md.

zh-TW pages follow the terminology rule already present in
`freeze.zh-TW.md` admonition (CLI / flag / package names preserved in
English; prose translated; first-occurrence English-in-parens for ambiguous
technical terms).

### 10. `mkdocs.yml` — nav + nav_translations

Under `nav:` → `Tools:` → `Shell & terminal:` (lines 209-269 from the
exploration), add the four entries grouped together (Charm CLI block
already groups Freeze/Glow/Gum/VHS; the new media block goes after VHS):

```yaml
        - FFmpeg (audio / video toolkit): tools/ffmpeg.md
        - ImageMagick (image swiss army knife): tools/imagemagick.md
        - ExifTool (image / video metadata): tools/exiftool.md
        - libvips (high-throughput image processing): tools/libvips.md
```

Add matching entries in `plugins.i18n.languages[zh-TW].nav_translations`
(currently around lines 58-112 from the exploration). Per the repo's
"terminology preserved in English" rule, only the parenthetical
description gets translated — tool names stay English:

```yaml
            FFmpeg (audio / video toolkit): FFmpeg (音訊 / 影片工具箱)
            ImageMagick (image swiss army knife): ImageMagick (圖片瑞士刀)
            ExifTool (image / video metadata): ExifTool (圖片 / 影片 metadata)
            libvips (high-throughput image processing): libvips (高吞吐圖片處理)
```

Verification: `uv run mkdocs build --strict` must pass after these edits
(per CLAUDE.md "docs/ + MkDocs site → mkdocs.yml nav" rule).

### 11. `dot_ansible/roles/devtools/tasks/main.yml` — update VHS comment

The existing comment at line 1450 says ffmpeg is "NOT auto-installed"; this
is no longer fully accurate when `installMediaTools=true`. Edit to:

```yaml
# Note: vhs requires `ttyd` and `ffmpeg` at runtime to record. ttyd is
# auto-installed by this devtools role (heavy via `apt`, light via Homebrew).
# ffmpeg is NOT installed here — opt in via `installMediaTools=true` (which
# also pulls in ImageMagick / exiftool / libvips). See docs/tools/vhs.md and
# docs/tools/ffmpeg.md.
```

(Exact wording can vary; the goal is to point readers at the new bundle.)

### 12. `README.md` — Tools section

Add a row in the "What You Get > Tools" section (per CLAUDE.md "README.md"
mirror rule). One-liner format matching the existing rows:

```markdown
| Media / AV CLIs | `installMediaTools` | ffmpeg, ImageMagick, exiftool, libvips |
```

If there's no existing table, mirror the prose style of the section. Keep
README.md concise — technical detail belongs in `docs/tools/*.md`.

---

## Critical files to read before editing

- `/Users/daviddwlee84/.local/share/chezmoi/.chezmoi.toml.tmpl:67-72` —
  reference pattern for `installNetworkingTools` / `installIacTools`.
- `/Users/daviddwlee84/.local/share/chezmoi/Dockerfile:21-22, 136-137` —
  ARG + `--promptBool` lockstep.
- `/Users/daviddwlee84/.local/share/chezmoi/scripts/init/dotfiles_init.py:113-227,236-289,622-674` —
  PROMPTS schema, BUNDLES, doctor parity check.
- `/Users/daviddwlee84/.local/share/chezmoi/dot_ansible/roles/networking_tools/tasks/main.yml:1-60` —
  closest structural twin (macOS Homebrew block + Linux apt block).
- `/Users/daviddwlee84/.local/share/chezmoi/dot_ansible/playbooks/{linux,macos}.yml` —
  role registration.
- `/Users/daviddwlee84/.local/share/chezmoi/.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl:35-37,161-172,258-260` —
  hash comment + tag injection + noRoot tag-strip semantics.
- `/Users/daviddwlee84/.local/share/chezmoi/docs/tools/freeze.md` —
  canonical single-CLI doc template (heading structure to clone).
- `/Users/daviddwlee84/.local/share/chezmoi/docs/zsh/aliases.md:1-30` —
  table format + maintenance-rule preamble.

---

## Verification

Run in this order after edits land:

1. **Schema parity**:
   `uv run --script scripts/init/dotfiles_init.py doctor`
   — must report "All three surfaces agree (keys + prompt texts)" with
   no drift. (Catches mismatched prompt text between
   `.chezmoi.toml.tmpl` and the `Prompt(...)` `prompt_text` field.)

2. **Chezmoi templating**:
   `chezmoi execute-template < .chezmoi.toml.tmpl` (or `chezmoi init --debug
   --apply=false` in a scratch dir) — verifies the new
   `promptBoolOnce` line parses.

3. **Ansible syntax** (from a host where ansible is installed):
   `cd ~/.ansible && ansible-playbook --syntax-check playbooks/linux.yml`
   and the same for `macos.yml`. Should report 0 errors.

4. **Ansible dry-run** for the new role only:
   `cd ~/.ansible && ansible-playbook -i inventories/localhost.ini
   playbooks/<linux|macos>.yml --tags media_tools --check --diff`
   — should plan to install the four packages and not touch anything else.

5. **Wet run** (one host, opt-in):
   - macOS: `chezmoi apply` after setting `installMediaTools=true` in
     `~/.config/chezmoi/chezmoi.toml`. Expected: 4 brew packages installed.
   - Ubuntu: same, expect 4 apt packages.
   - Verify: `ffmpeg -version`, `magick --version` (or `convert --version`),
     `exiftool -ver`, `vips --version` all return non-zero output.

6. **Docs build (strict)**:
   `uv run mkdocs build --strict` — fails on broken nav links, missing
   nav_translations, or stale anchors. Must pass before the PR merges.

7. **Zsh helpers**:
   `source dot_config/zsh/tools/29_media.zsh && type compress-video
   extract-audio to-wav16k` should print three function definitions on a
   host with ffmpeg installed; **no output** (and no error) on a host
   without ffmpeg (the `${+commands[ffmpeg]}` guard).

8. **Docker smoke test**:
   `docker build --build-arg CHEZMOI_PROFILE=ubuntu_server
   --build-arg CHEZMOI_INSTALL_MEDIA_TOOLS=true .` — verifies the
   Dockerfile flag is wired and the prompt-text match works
   non-interactively.

---

## Out of scope / explicit non-goals

- No `state: latest` / no upgrade hooks. Per the
  "Install vs upgrade is split on purpose" invariant in CLAUDE.md, upgrades
  flow through `just upgrade-*` recipes only. The generic upgrade path will
  pick these up automatically (apt + brew) — no new category needed.
- No `yt-dlp`, no `whisper.cpp`, no `Pillow`/`OpenCV`. The ChatGPT chat
  mentioned them adjacently but they're outside the user's confirmed scope.
- No new fleet-apply integration — `installMediaTools` flows through the
  same chezmoi-init prompt → ansible-tag pipeline that all the other
  optional bundles use, so `just fleet-apply` already handles it.
- No `pre-commit` / linter changes — yaml + zsh + markdown all already
  have hooks and they don't need new rules.
