# System audio & media control (`sys*`)

Cross-platform shell helpers to control **system volume, mute, multimedia playback, and "what's playing"** from the command line — and, via `fleet`, across every host at once (a remote one-key mute).

Same verb names on both OSes for muscle memory; backends diverge:

| Verb | What it does | macOS backend | Linux backend |
|---|---|---|---|
| `sysvol [N\|+N\|-N]` | get / set / adjust output volume (0–100) | `osascript` | `wpctl` → `pactl` → `amixer` |
| `sysmute [on\|off\|toggle]` | mute system output (default toggle) | `osascript` | `wpctl` → `pactl` → `amixer` |
| `sysplay [next\|previous]` | toggle play/pause, or skip track | `nowplaying-cli` or per-app AppleScript | `playerctl` (MPRIS) |
| `sysnow` | print currently playing `Artist - Title` | `nowplaying-cli` / per-app AppleScript | `playerctl metadata` |

Source: [`dot_config/shell/57_macos_audio.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/57_macos_audio.sh.tmpl) and [`57_linux_audio.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/57_linux_audio.sh.tmpl).

## Two tiers

**Built-in (always deployed, no opt-in)** — `sysvol` and `sysmute` work everywhere with only OS built-ins. On macOS that's `osascript`; on Linux it's whichever of `wpctl` (PipeWire), `pactl` (PulseAudio — also fronts PipeWire via `pipewire-pulse`), or `amixer` (ALSA) is present. Override the Linux backend with `SYSAUDIO_BACKEND=wpctl|pactl|amixer`.

**Extended (opt-in via `installMediaControl=true`)** — `sysplay`/`sysnow` need the extra CLIs installed by the [`media_control` ansible role](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/media_control/tasks/main.yml):

- macOS: `nowplaying-cli` (app-agnostic transport + `get`), `switchaudio-osx` (`SwitchAudioSource` — list/switch output devices).
- Linux: `playerctl` (MPRIS over D-Bus, drives any compliant player), `pulseaudio-utils` (guarantees `pactl`).

Without the opt-in, `sysplay`/`sysnow` print a one-line install hint instead of failing silently. (Related but distinct: `installMediaTools` installs ffmpeg/ImageMagick for *file* processing — see [ffmpeg](ffmpeg.md). Different role, different purpose.)

## Examples

```sh
sysvol            # → 45   (current volume)
sysvol 30         # set to 30
sysvol +5         # bump up 5
sysvol -10        # drop 10
sysmute           # toggle
sysmute on        # force mute
sysplay           # play/pause the active player
sysplay next      # skip track
sysnow            # → "Radiohead - Weird Fishes [Playing]"
```

## Remote one-key mute via fleet

`fleet exec`'s default mode runs non-interactively and does **not** source `dot_config/shell/`, so the functions aren't defined. Add `--login` so the remote rc files load them:

```sh
fleet exec --login --group all -- sysmute on     # mute every host
fleet exec --login --group all -- sysvol 20
```

## Caveats

### macOS now-playing is degraded on 15.4+

Apple locked the private **MediaRemote** framework in macOS 15.4 (Sequoia), so `nowplaying-cli get` returns empty on current macOS. `sysnow` therefore degrades to **per-app AppleScript** and only sees **Music / Spotify** (not Safari/Chrome web audio), printing a one-line caveat when nothing is detectable. Transport (`sysplay`) is unaffected. A future option is the [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter) bridge (out of scope for now).

### Linux playback over SSH needs a D-Bus session bus

`sysplay`/`sysnow` talk to players over MPRIS, which requires `DBUS_SESSION_BUS_ADDRESS`. Background SSH sessions usually lack a session bus, so `fleet exec` may not be able to drive playback on remote hosts — but `sysvol`/`sysmute` go through `wpctl`/`pactl` and are unaffected, so **remote mute still works**.

## See also

- [Aliases & functions catalog → System audio & playback](../shells/aliases.md#system-audio--playback)
- [Tool managers → Tool index (A–Z)](../this_repo/tool-managers.md#tool-index-az) (`nowplaying-cli`, `switchaudio-osx`, `playerctl`)
- [macOS app control (`app-*`)](../shells/aliases.md#macos-apps) — the sibling helper family this mirrors
