# Cross-platform system audio / media control helpers (`sys*`)

## Context

The user wants a CLI-driven way to control **system volume, mute, multimedia playback, and "what's playing"** on both macOS and Linux — primarily so `fleet` can do things like a **remote one-key mute** across all hosts. Today the repo has **no** system-audio helper (`29_media.sh` is file-processing ffmpeg/ImageMagick, not playback; `playerctl` is only referenced inside `56_linux_apps.sh.tmpl`'s responsiveness probe).

Design decisions confirmed with the user:
- **Naming**: `sys*` prefix — `sysvol`, `sysmute`, `sysplay`, `sysnow`.
- **Scope**: full — volume + mute + playback control + now-playing query.
- **fleet**: plain shell functions invoked via `fleet exec --login` (matches the `app-*` precedent; no new executable/completion surface).
- **Two-tier** per the user's "如果關聯的工具較多就做成 init 選項" request:
  - **Built-in tier (always deployed, no opt-in)**: volume/mute fully covered everywhere; playback + now-playing best-effort with OS built-ins, degrading gracefully.
  - **Extended tier (init opt-in → ansible role)**: installs the extra CLIs that unlock full playback control + reliable now-playing; if not selected, only built-ins are used.

The whole thing mirrors the existing **`app-*` helper pattern** (`54_macos_apps.sh.tmpl` / `56_linux_apps.sh.tmpl`): two OS-gated POSIX shell files, `_prefix_guard_os` guards, public bare verbs, graceful fallback.

### Capability matrix (drives built-in vs extended split)

| Verb | macOS built-in | macOS extended | Linux built-in | Linux extended |
|---|---|---|---|---|
| `sysvol` get/set/±N | `osascript` ✅ | — | `wpctl`/`pactl`/`amixer` ✅ | — |
| `sysmute` on/off/toggle | `osascript` ✅ | — | `wpctl`/`pactl`/`amixer` ✅ | — |
| `sysplay` play-pause/next/prev | per-app AppleScript (Music/Spotify if running) ⚠ | `nowplaying-cli` (any app) ✅ | — (hint) | `playerctl` (MPRIS) ✅ |
| `sysnow` what's playing | per-app AppleScript ⚠ | `nowplaying-cli get` ⚠* | — (hint) | `playerctl metadata` ✅ |

\* **macOS now-playing caveat**: Apple locked the MediaRemote private framework in macOS 15.4+; this host is **26.2**, so `nowplaying-cli get` may return empty. Functions must degrade to per-app AppleScript and print a one-line caveat rather than silently failing. (Documented, not worked around — the [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter) bridge is out of scope for v1.)

---

## Implementation

### 1. Built-in tier — two OS-gated shell helpers

Mirror `54_macos_apps.sh.tmpl` / `56_linux_apps.sh.tmpl` conventions exactly: `# shellcheck shell=sh`, OS template gate, `_sysaudio_*` private guards/helpers, `-h|--help` case per verb, `printf` (not `echo`), exit codes + stderr hints.

**`dot_config/shell/57_macos_audio.sh.tmpl`** — gate `{{- if eq .chezmoi.os "darwin" -}}`
- `_sysaudio_guard_darwin`, `_sysaudio_have() { command -v "$1" >/dev/null 2>&1; }`
- `sysvol [N|+N|-N]` — no arg prints `output volume of (get volume settings)`; `N` → `set volume output volume N`; `±N` reads current then clamps 0–100.
- `sysmute [on|off|toggle]` — default `toggle`; `set volume output muted (true|false|not current)`. **This is the remote-mute primitive.**
- `sysplay [next|previous|""]` — extended: `nowplaying-cli {next|previous|togglePlayPause}` if present; else per-app AppleScript to whichever of Music/Spotify is running (`tell application "X" to playpause`/`next track`); else stderr hint.
- `sysnow` — extended `nowplaying-cli get` (guard empty output → fall through); else per-app AppleScript `name`/`artist of current track`; else hint pointing at the init opt-in. Print the MediaRemote caveat when empty.
- (optional) device switching deferred — only via `SwitchAudioSource` (extended); mention in `--help`, not a core verb in v1.

**`dot_config/shell/57_linux_audio.sh.tmpl`** — gate `{{- if eq .chezmoi.os "linux" -}}`
- `_sysaudio_sink_backend()` — caches first hit of `wpctl` → `pactl` → `amixer` (richest first). `pactl` chosen as the common case (works on both PulseAudio and PipeWire via `pipewire-pulse`).
- `sysvol [N|+N|-N]` / `sysmute [on|off|toggle]` — dispatch on backend:
  - wpctl: `get-volume`/`set-volume @DEFAULT_AUDIO_SINK@ N%`/`set-mute … toggle`
  - pactl: `get-sink-volume`/`set-sink-volume @DEFAULT_SINK@ N%`/`set-sink-mute @DEFAULT_SINK@ toggle`
  - amixer: `get Master`/`set Master N%`/`set Master toggle`
- `sysplay [next|previous|""]` / `sysnow` — `playerctl` (extended). If absent, stderr hint: `playerctl not installed — re-run chezmoi init with installMediaControl=true`. `sysnow` → `playerctl metadata --format '{{ "{{" }}artist{{ "}}" }} - {{ "{{" }}title{{ "}}" }}'` (note Go-template escaping inside the `.tmpl`) + `playerctl status`.
- Cross-platform parity promise documented in the header, same as `56_linux_apps.sh.tmpl`.

Both files use the runtime `command -v` degradation idiom (like `56_clipboard_history.sh`'s `_clip_backend`) so the **built-in tier works with zero opt-in** and the extended tools, when present, are picked up automatically.

> Numeric prefix `57` is free for both (54/55 = macOS apps/mem, 56 = linux_apps/clipboard). The two files never coexist (OS-gated), so sharing `57` is fine and keeps them adjacent to the `app-*` system-control block.

### 2. Extended tier — init prompt + ansible role

**`scripts/init/dotfiles_init.py`** — add one `Prompt` to the `PROMPTS` tuple (model on the `installBitwarden` entry, bilingual `comment`):
```python
Prompt("installMediaControl", "bool", "System & apps",
       "System media/audio control CLIs",
       "nowplaying-cli + switchaudio-osx (macOS), playerctl (Linux). Unlocks full sysplay/sysnow; built-in sysvol/sysmute work without it.",
       default=False,
       prompt_text="Install system media-control CLIs (nowplaying-cli/switchaudio-osx on macOS, playerctl on Linux)",
       comment=("是否安裝系統媒體控制 CLI…(macOS: nowplaying-cli, switchaudio-osx; Linux: playerctl)\n"
                "不裝也能用 built-in sysvol/sysmute;裝了才有完整 sysplay/sysnow。詳見 docs/tools/media-control.md"))
```
- **Distinct key from the existing `installMediaTools`** (that one = ffmpeg/ImageMagick file processing; do not conflate).
- Run **`just gen-prompts`** — regenerates the marker regions in `.chezmoi.toml.tmpl`, `Dockerfile`, and the README option table automatically. **Never hand-edit those regions.** Verify with `just gen-prompts -- --check`.

**`dot_ansible/roles/media_control/tasks/main.yml`** — new role, copy the shape of `dot_ansible/roles/media_tools/tasks/main.yml`:
- macOS block `when: ansible_facts["os_family"] == "Darwin"`, `community.general.homebrew`: `nowplaying-cli`, `switchaudio-osx`.
- Linux block `when: ansible_facts["os_family"] == "Debian"`, `become: true`, `tags: [sudo]`, `ansible.builtin.apt`: `playerctl`, `pulseaudio-utils` (guarantees `pactl` is present even on a PipeWire box via `pipewire-pulse`).

**`dot_ansible/playbooks/macos.yml` + `linux.yml`** — add `- role: media_control` / `tags: [media_control]` (roles are always declared; tags select).

**`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`** — add tag gating next to the `installMediaTools` block:
```bash
{{ $installMediaControl := false }}{{ if hasKey . "installMediaControl" }}{{ $installMediaControl = .installMediaControl }}{{ end -}}
{{ if $installMediaControl -}}
TAGS="${TAGS},media_control"
{{ end -}}
```

### 3. Docs / agent-surface maintenance (same-commit rules from CLAUDE.md)

- **`docs/shells/aliases.md`** — add `sysvol`/`sysmute`/`sysplay`/`sysnow` rows under the (currently empty) **"Media / AV"** section, type=function, source=`57_*_audio.sh`.
- **`docs/this_repo/tool-managers.md`** — add A–Z rows for `nowplaying-cli`, `switchaudio-osx`, `playerctl` (manager = brew/apt, gated on `installMediaControl`).
- **`dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`** — add a `{{- if dig "installMediaControl" false . }} … {{- end }}` gated one-liner pointing at the `sys*` helpers (gated because it's a new prompt key — per the CLAUDE.md rule).
- **`docs/tools/media-control.md`** (new) + nav entry in **`mkdocs.yml`** — usage, the two-tier model, the macOS MediaRemote-lockdown caveat, the `fleet exec --login` recipe, the Linux D-Bus-over-SSH gotcha. Run `uv run mkdocs build --strict`.
- **`README.md`** — "What You Get" gets a brief mention; the init-option row is auto-generated by `gen-prompts`.
- **No tab-completion files** — plain shell functions don't need them (only `executable_*` CLIs do, per `docs/zsh/zsh-completions.md` §F). **No tv channel** in v1 (volume isn't list-shaped; a `tv` now-playing picker is a possible later follow-up).

### 4. fleet usage (documentation only — no code)

`fleet exec` default mode runs non-interactively and does **not** source `dot_config/shell/`; `--login` loads rc files so the functions are defined. Document the recipe:
```bash
fleet exec --login --group all -- sysmute on      # remote one-key mute
fleet exec --login --group all -- sysvol 20
```
Note the **Linux D-Bus caveat**: `sysplay`/`sysnow` over SSH need a `DBUS_SESSION_BUS_ADDRESS` (background SSH sessions often lack a session bus) — `sysvol`/`sysmute` via `pactl`/`wpctl` are unaffected. This is the most common remote-media failure mode; call it out in the docs.

---

## Verification

1. **Render**: `chezmoi execute-template < dot_config/shell/57_macos_audio.sh.tmpl` (and the linux one) — confirm clean Go-template output, especially the escaped `playerctl --format '{{...}}'` braces.
2. **Built-in smoke (this macOS host)**: source the rendered file; `sysvol` (expect a number), `sysmute on` then `sysmute off` (verify via `osascript -e 'output muted of (get volume settings)'`), `sysvol +5` / `sysvol 45` round-trip. `sysnow` with no player → prints the MediaRemote caveat, not a stack trace.
3. **Prompt drift**: `just gen-prompts -- --check` exits 0; `installMediaControl` row present in README table + `.chezmoi.toml.tmpl` marker region.
4. **Ansible**: `ansible-playbook dot_ansible/playbooks/macos.yml --syntax-check`; narrowest real run `--tags media_control --check` (or container smoke for the Linux apt path) — per the "validate with the app" invariant, not just syntax.
5. **Docs**: `uv run mkdocs build --strict` passes with the new page + nav entry.
6. **fleet (manual, if a second host is reachable)**: `fleet exec --login --group all -- sysmute on` mutes remotes; confirm `sysvol`/`sysmute` work without `installMediaControl`, and `sysplay`/`sysnow` print the install hint when the extended tools are absent.

## Out of scope (note as follow-ups)
- `mediaremote-adapter` bridge to restore macOS now-playing reads post-15.4.
- A `tv media`/now-playing picker channel.
- Output-device switching as a first-class `sys*` verb (only mentioned in `--help` via `SwitchAudioSource`).
