# Linux/Ubuntu equivalent of `54_macos_apps.sh` — graceful desktop app control

**Status**: **P2 implemented (partial coverage by design)** — shipped 2026-05-13
**Effort**: M (delivered) → L (deferred KDE / Sway / Hyprland follow-ups)
**Implementation**: [`dot_config/shell/56_linux_apps.sh.tmpl`](../dot_config/shell/56_linux_apps.sh.tmpl) (the helper) · [`dot_config/television/cable/linux-apps.toml.tmpl`](../dot_config/television/cable/linux-apps.toml.tmpl) (the picker) · [`docs/playbooks/linux-gui-apps.md`](../docs/playbooks/linux-gui-apps.md) → "Controlling installed apps from the shell" section
**Related**: [`dot_config/shell/54_macos_apps.sh.tmpl`](../dot_config/shell/54_macos_apps.sh.tmpl) (macOS counterpart, same verb names) · `pitfalls/linux-app-control-appimage-runtime-path.md` · `pitfalls/linux-app-control-gapplication-zero-coverage.md`

## Context

2026-05-13, conversation prompt: *"不知道 Ubuntu 的 Desktop App 有沒有類似的機制？幫我搜一下？"* — followed by *"我們在 Ubuntu Desktop 機器上 評估是否能做出類比的commands 有沒有什麼坑？"*

Came up right after shipping `54_macos_apps.sh` + `tv mac-apps` channel (commits `ce5e23a` + `2fc5031`). The macOS side uses `osascript` to send Apple Events for graceful Quit / Launch / Activate / Restart / Hide, plus a best-effort responsiveness probe via `with timeout`. Question: what's the Linux/Ubuntu equivalent so we can mirror the `app-*` helpers + `tv mac-apps` picker on `ubuntu_desktop` hosts?

**Short answer**: no single equivalent exists. Linux desktop control is fragmented across (display server) × (compositor / WM) × (desktop env) × (per-app D-Bus support). Wayland intentionally restricts cross-app introspection for security — by design there is no public API to "list all windows" or "send a quit event" from outside the compositor.

**Shipped pivot**: hybrid `gtk-launch` + `pkill -TERM` + optional GNOME `window-calls` extension, with a per-user override file for AppImage / Snap / Flatpak runtime-path corrections. 5 of 7 macOS verbs translate cleanly; 1 (`appactivate`) degrades to best-effort without the extension; 1 (`appresponsive`) is MPRIS-only.

## Empirical findings — Ubuntu 24.04, GNOME Shell 46.0, Wayland

Probed against the user's actual app set (Zen, Cursor, Spotify, Discord, Frpc-Desktop):

1. **`gapplication` has 0% coverage of third-party apps**, not "patchy good" as the initial research assumed. `gapplication list-apps` returned **13 entries, all GNOME-core** (Calendar, Logs, Nautilus, Totem, …). None of the user's 5 apps had `DBusActivatable=true` in their `.desktop` files. → option A from the earlier matrix is **dead** for a daily-driver Ubuntu desktop. See `pitfalls/linux-app-control-gapplication-zero-coverage.md`.
2. **AppImage runtime path ≠ `.desktop` `Exec=` path.** Zen's `.desktop` says `~/Applications/zen-x86_64_*.AppImage`; the actual running process is at `/tmp/.mount_remp*/zen`. `pkill -f <Exec-path>` only hits the launcher wrapper, not the real binary. See `pitfalls/linux-app-control-appimage-runtime-path.md`.
3. **`.desktop` cruft is the norm, not the exception.** Zen had 4 `.desktop` entries (3 AppImage residues + 1 custom userapp). Cursor had 2 (apt at `/usr/share/cursor/cursor` + AppImage). Discord had 2 (apt + Flatpak — both installed, only apt actually running).
4. **`gtk-launch` / `dex` / `gio` work for any `.desktop` file** regardless of `DBusActivatable`. This is the bright spot — launch is fully solvable without the gapplication assumption.
5. **All 5 user apps had `StartupWMClass` set.** Good news for compositor-aware focus IF the GNOME `window-calls` extension is installed.
6. **No fallback tools installed by default**: `playerctl`, `wmctrl`, `xdotool`, `wlrctl`, `ydotool`, `wtype`, `qdbus`. Only D-Bus core (`gapplication`, `gdbus`, `busctl`, `dbus-send`). The ansible role now installs `playerctl` + `wmctrl` + `xdotool` via apt.
7. **`window-calls` install can be automated** via `gnome-extensions install <bundle.zip>`, but the user-consent dialog on GNOME 46+ cannot be silenced, AND Wayland sessions require a full logout + login to activate the extension. Documented as a one-time manual step.

## What shipped

**Helper** (`dot_config/shell/56_linux_apps.sh.tmpl`, gated on `eq .chezmoi.os "linux"`): same 7 public verbs as macOS counterpart, plus `linux_app_register` for explicit overrides.

| Verb | Linux backend | Fidelity |
|---|---|---|
| `applaunch NAME` | `gtk-launch <desktop-id>` via `setsid -f` | ✓ all apps with a `.desktop` file |
| `apprunning NAME` | `pgrep -f <pattern>` | ✓ silent boolean |
| `appquit NAME` | `pkill -TERM -f <pattern>` | ✓ Electron + Firefox honour SIGTERM as graceful quit |
| `apprestart NAME` | quit + poll-gone (≤15s) + launch (launches even if not running) | ✓ |
| `appactivate NAME` | D-Bus → `org.gnome.Shell.Extensions.Windows.Activate(<wm-class>)` if `window-calls` ext present; else `applaunch` fallback | ⚠ true focus needs extension; degrades gracefully |
| `applist [--pids\|--all]` | registry + `.desktop` scan with absolute-Exec filter, pgrep each | ⚠ "managed apps that are alive" — not every window |
| `appresponsive NAME [T]` | `timeout T playerctl -p <mpris> status` for media apps; degrades to `apprunning` + stderr note otherwise | ⚠ MPRIS-only; no Linux analog to Apple Events |

**Override file** (`~/.config/shell/linux-apps.conf`, not auto-stubbed): `linux_app_register NAME --desktop=ID --pkill=REGEX --wm-class=CLASS [--mpris=NAME]`. Required for AppImage / Snap / Flatpak apps; recommended where multiple `.desktop` entries exist for one app. See the playbook for the user's 5-app starter snippet.

**tv channel** (`dot_config/television/cable/linux-apps.toml.tmpl`, gated on linux + `ubuntu_desktop`): mirrors `tv mac-apps` keybindings. Drops Alt+H (no Linux "hide windows" without compositor IPC).

**ansible role**: `gui_apps_linux` now installs `playerctl` + `wmctrl` + `xdotool` via apt (tags: `sudo, app_control`).

## Open follow-ups (deferred)

1. **KDE / KWin backend**: `qdbus org.kde.KWin /KWin …` + `kdotool`. File when a KDE host joins the fleet.
2. **Sway backend**: `swaymsg "[app_id=…] focus"` — cleanest IPC of any compositor, scriptable. File when a Sway host joins.
3. **Hyprland backend**: `hyprctl dispatch …`, JSON-RPC. File when a Hyprland host joins.
4. **Automated `window-calls` install**: blocked by GNOME 46+ user-consent dialog. Revisit when GNOME ships a non-interactive install flag.
5. **`appresponsive` parity for non-MPRIS apps**: open research. Possible angles: `/proc/<pid>/wchan` heuristic, X11 `_NET_WM_PING` (X11-only), per-app D-Bus introspect-with-timeout (works only for apps with well-known names).

## References

- [Successor of wmctrl, xdotool, devilspie2, kpie — Fedora Discussion](https://discussion.fedoraproject.org/t/successor-of-wmctrl-xdotool-devilspie2-kpie/79507)
- [Exploring the Fragmentation of Wayland, an xdotool adventure (semicomplete)](https://www.semicomplete.com/blog/xdotool-and-exploring-wayland-fragmentation/)
- [Which tools can I use in place of wmctrl and xdotool? — Ubuntu Forums](https://ubuntuforums.org/showthread.php?t=2475972)
- [Xdotool replacement on wayland — KDE Discuss](https://discuss.kde.org/t/xdotool-replacement-on-wayland/7242)
- [Wlrctl: Wayland replacement to xdotool — Raspberry Pi Forums](https://forums.raspberrypi.com/viewtopic.php?t=371406)
- [Control Your Linux Desktop with D-Bus — Linux Journal](https://www.linuxjournal.com/article/10455)
- [D-Bus — Wikipedia](https://en.wikipedia.org/wiki/D-Bus)
- [gapplication: D-Bus application launcher — Arch man page](https://man.archlinux.org/man/core/glib2/gapplication.1.en)
- [HowDoI/GtkApplication/CommandLine — GNOME Wiki Archive](https://wiki.gnome.org/HowDoI(2f)GtkApplication(2f)CommandLine.html)
- [`window-calls` GNOME Shell extension (ickyicky)](https://github.com/ickyicky/window-calls) — GNOME Wayland window-listing via D-Bus
- [`window-calls-extended` GNOME Shell extension (hseliger)](https://github.com/hseliger/window-calls-extended) — fork with GNOME 45+ updates
- [Extension: Get list of windows — GNOME Discourse](https://discourse.gnome.org/t/extension-get-list-of-windows/19455)
- [playerctl (altdesktop) — MPRIS CLI](https://github.com/altdesktop/playerctl) — the one cross-DE bright spot
