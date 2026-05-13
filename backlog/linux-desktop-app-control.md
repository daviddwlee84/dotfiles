# Linux/Ubuntu equivalent of `54_macos_apps.sh` — graceful desktop app control

**Status**: P? deferred — evaluation only, pending hands-on Ubuntu Desktop experimentation
**Effort**: M (gapplication-only subset) → L (full compositor-aware dispatch)
**Related**: [`dot_config/shell/54_macos_apps.sh.tmpl`](../dot_config/shell/54_macos_apps.sh.tmpl) (the macOS side we want to mirror) · [`dot_config/television/cable/mac-apps.toml.tmpl`](../dot_config/television/cable/mac-apps.toml.tmpl) (companion tv picker) · `TODO.md` → `[?/M] linux-mem-status / linux-mem-reclaim helpers` (sister Linux-mirror entry) · `[?/M] Linux Desktop app control equivalent of 54_macos_apps.sh` (this entry)

## Context

2026-05-13, conversation prompt: *"不知道 Ubuntu 的 Desktop App 有沒有類似的機制？幫我搜一下？"*

Came up right after shipping `54_macos_apps.sh` + `tv mac-apps` channel (commits `ce5e23a` + `2fc5031`). The macOS side uses `osascript` to send Apple Events for graceful Quit / Launch / Activate / Restart / Hide, plus a best-effort responsiveness probe via `with timeout`. Question: what's the Linux/Ubuntu equivalent so we can mirror the `app-*` helpers + `tv mac-apps` picker on `ubuntu_desktop` hosts?

Short answer from the research: **no single equivalent**. Linux desktop control is fragmented across (display server) × (compositor / WM) × (desktop env) × (per-app D-Bus support). Wayland intentionally restricts cross-app introspection for security — by design there is no public API to "list all windows" or "send a quit event" from outside the compositor.

## Investigation

Three mechanism families exist, none of them universal.

### 1. D-Bus — the actual semantic analog to Apple Events

D-Bus is the IPC bus that every modern Linux DE uses. **Closest model match to macOS Apple Events**: apps expose objects/interfaces, you call methods on them. Works on **both X11 and Wayland**.

CLI tools:
- `gapplication` — high-level, freedesktop `org.freedesktop.Application` interface
- `gdbus` / `qdbus` / `busctl` / `dbus-send` — low-level
- `dbus-monitor` — sniff bus events (debug)

Practical examples:
```bash
gapplication list-apps                          # all DBusActivatable=true apps
gapplication launch org.gnome.Calculator        # launch (or activate if running)
gapplication launch org.gnome.gedit ./file.md   # open with file
gapplication list-actions org.gnome.Calculator  # what methods does it expose?
gapplication action org.gnome.gedit quit        # graceful quit — IF app exposes it
```

**Catch**: every app must opt-in by setting `DBusActivatable=true` in its `.desktop` file AND expose `quit`/`activate`/etc actions. Many third-party apps don't. Coverage is patchy — closer to "macOS apps with sane Apple-Event support" (~good) than "every app in /Applications" (~universal).

### 2. wmctrl / xdotool — X11 only, broken on Wayland

`wmctrl -l` (list), `wmctrl -c "Firefox"` (close), `xdotool search --name`. **Closest functional mirror to AppleScript's window targeting** but **only works on X11 windows**. On Ubuntu 24.04+ default Wayland session, only legacy apps running under XWayland respond; native Wayland apps are invisible.

Dead-end for new code. Don't build on these.

### 3. Compositor-specific tools

When you must control native Wayland windows, you drop down to whatever your compositor exposes:

| Compositor | Tool | Notes |
|---|---|---|
| **GNOME Shell** (Ubuntu default) | `gdbus call --session --dest org.gnome.Shell …` | Restricted in recent GNOME for security. Needs a Shell extension like [`window-calls`](https://github.com/ickyicky/window-calls) or [`window-calls-extended`](https://github.com/hseliger/window-calls-extended) to expose `List/Details/Activate` D-Bus interface. **Extension install can't be fully automated** — defeats `chezmoi apply` automation if rolled out via ansible. |
| **KDE / KWin** | `qdbus org.kde.KWin /KWin …` + `kdotool` | KDE-only. |
| **Sway** (wlroots) | `swaymsg "[app_id=firefox] focus"` | **Cleanest of the bunch** — IPC is first-class, scriptable. |
| **Hyprland** | `hyprctl dispatch killactive`, `hyprctl clients` | Hyprland's own JSON-RPC. |
| **Generic wlroots** | `wlrctl` | Only works if compositor supports `wlr-foreign-toplevel-management` protocol. |

For input simulation across Wayland: `ydotool` (replaces `xdotool`, needs a root daemon `ydotoold` via systemd) or `wtype` (keyboard only).

### Bonus: MPRIS for media players

**The one cross-desktop standard that actually works universally**: media players expose `org.mpris.MediaPlayer2.*` over D-Bus. `playerctl play-pause` works for Spotify, VLC, Firefox, Chromium, mpv, anything compliant. No compositor coupling. Closest thing Linux has to "AppleScript universal support" — but only for media controls.

### Mapping back to the macOS helper surface

| macOS helper (`54_macos_apps.sh`) | Linux closest equivalent | Coverage |
|---|---|---|
| `appquit NAME` | `gapplication action <app-id> quit` | Good for GNOME apps, hit-or-miss for third-party |
| `applaunch NAME` (background) | `gapplication launch <app-id>` | Good — bus-activated launch |
| `appactivate NAME` (foreground) | `gapplication launch <app-id>` (same) OR compositor-specific focus | gapplication doesn't distinguish; needs compositor for true focus |
| `apprestart NAME` | quit + launch (compose the above) | Inherits both sides' patchiness |
| `apprunning NAME` | `gdbus introspect --session --dest <bus-name>` returns non-error | Works if app has a well-known bus name |
| `applist` | `gapplication list-apps` (registered apps, NOT running) | **Semantic mismatch** — lists installable, not running |
| `applist --pids` | GNOME `window-calls` ext, KDE qdbus, sway/hyprctl | Compositor-specific, no universal answer |
| `appresponsive NAME` | No public API. Would need ping over the app's D-Bus interface with timeout | Best-effort, similar to macOS proxy |

## Options considered

| Option | Coverage | Effort | Notes |
|---|---|---|---|
| **A. D-Bus-only (`gapplication` + `gdbus`)** | Apps that expose interfaces (~good for GNOME, patchy elsewhere) | Low (~80 LOC) | Cross-DE, works on both X11 + Wayland. Misses many third-party apps. Honest first cut. |
| **B. Compositor-specific (Sway / Hyprland / KDE)** | Full window control on that compositor | Medium per compositor | Only useful if you commit to one compositor. Unrealistic for `ubuntu_desktop` (defaults to GNOME). |
| **C. GNOME + `window-calls` extension** | Full control on GNOME Wayland | Low after the extension install (which is manual) | Extension install is not silent — would need user consent step, can't ansible-deploy. Defeats automation. |
| **D. X11-only (`wmctrl` + `xdotool`)** | Everything on X11 | Low | Forces users onto X11 session — backward step on Ubuntu 24.04+. Dead-end. |
| **E. Hybrid: D-Bus core + `playerctl` + compositor-detection stub** | gapplication coverage + universal media + room to extend | Medium | Most pragmatic. `XDG_SESSION_TYPE` + `XDG_CURRENT_DESKTOP` runtime gates, dispatch to the right backend, document patchy coverage upfront. |
| **F. Skip — Ubuntu side stays manual** | — | Zero | Most pragmatic given fragmentation. The `tv mac-apps` UX is macOS-specific; users on Ubuntu desktops would interact via the OS's own picker/wmctrl/keyboard shortcuts. |

## Current blocker / open questions

1. **No Ubuntu Desktop host to test against right now.** The user maintains `ubuntu_desktop` and `ubuntu_server` profiles but `ubuntu_server` is what most fleet hosts run today. Need a real `ubuntu_desktop` machine (Wayland session, GNOME default) to validate which apps actually expose `quit`/`activate` D-Bus actions — the research above is theory.

2. **GNOME `window-calls` extension install is not automatable.** It would need:
   - `gnome-extensions install --enable <extension.zip>` (CLI flow exists but requires `gnome-shell` reload + user consent dialog on recent GNOME)
   - OR document a one-time manual install step in the playbook
   - OR drop the window-listing requirement and only support gapplication-style lifecycle (no `applist`)

3. **Coverage acceptance threshold unknown.** If only ~30% of GUI apps respond to `gapplication action <id> quit`, is it still worth shipping? Need empirical measurement on a real desktop session against the user's actual app set.

4. **Compositor-detection complexity vs single-target focus.** Option E hedges across compositors; option C accepts the GNOME assumption upfront. The user's `ubuntu_desktop` Brewfile/role doesn't currently pin a compositor — open whether to enforce GNOME or leave it floating.

## Decision (pending)

**2026-05-13 deferred** — user wants to experiment on a real Ubuntu Desktop machine before committing to a path. Likely first spike when one of:

- A second Ubuntu Desktop joins the fleet (currently most Linux hosts are `ubuntu_server` headless).
- User explicitly wants `tv linux-apps` parity for daily driver workflow.
- Concrete coverage measurement on a real desktop session reveals option A is "good enough" (≥50% of daily-use apps).

When picking back up:
1. Start from option A (gapplication subset) — smallest blast radius, no extension dependency.
2. Measure coverage on the actual host's installed app set (`gapplication list-apps | wc -l` vs how many actually expose `quit`).
3. Promote to option E only if a second compositor (KDE on a niche host, Sway on a power-user laptop) joins the fleet.
4. File location: `dot_config/shell/56_linux_apps.sh.tmpl` (sibling to the deferred `56_linux_mem.sh.tmpl` per the `linux-mem-status` TODO entry), gated on `eq .chezmoi.os "linux"`.
5. tv channel mirror: `dot_config/television/cable/linux-apps.toml.tmpl` would reuse the same `tv mac-apps` UX (Enter=activate, Alt+Q=quit, etc.) but call gapplication.

## References

- [Successor of wmctrl, xdotool, devilspie2, kpie — Fedora Discussion](https://discussion.fedoraproject.org/t/successor-of-wmctrl-xdotool-devilspie2-kpie/79507) — community survey of the post-Wayland tool landscape
- [Exploring the Fragmentation of Wayland, an xdotool adventure (semicomplete)](https://www.semicomplete.com/blog/xdotool-and-exploring-wayland-fragmentation/) — root cause writeup of why no universal solution
- [Which tools can I use in place of wmctrl and xdotool? — Ubuntu Forums](https://ubuntuforums.org/showthread.php?t=2475972)
- [Xdotool replacement on wayland — KDE Discuss](https://discuss.kde.org/t/xdotool-replacement-on-wayland/7242)
- [Wlrctl: Wayland replacement to xdotool — Raspberry Pi Forums](https://forums.raspberrypi.com/viewtopic.php?t=371406)
- [Control Your Linux Desktop with D-Bus — Linux Journal](https://www.linuxjournal.com/article/10455)
- [D-Bus — Wikipedia](https://en.wikipedia.org/wiki/D-Bus)
- [gapplication: D-Bus application launcher — Arch man page](https://man.archlinux.org/man/core/glib2/gapplication.1.en)
- [HowDoI/GtkApplication/CommandLine — GNOME Wiki Archive](https://wiki.gnome.org/HowDoI(2f)GtkApplication(2f)CommandLine.html)
- [`window-calls` GNOME Shell extension (ickyicky)](https://github.com/ickyicky/window-calls) — GNOME Wayland window-listing via D-Bus
- [`window-calls-extended` GNOME Shell extension (hseliger)](https://github.com/hseliger/window-calls-extended) — fork with GNOME 45 updates
- [Extension: Get list of windows — GNOME Discourse](https://discourse.gnome.org/t/extension-get-list-of-windows/19455)
- [playerctl (altdesktop) — MPRIS CLI](https://github.com/altdesktop/playerctl) — the one cross-DE bright spot
