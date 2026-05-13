# `gapplication list-apps` only shows GNOME-core apps — Electron / AppImage / Snap / Flatpak invisible

**Symptoms** (grep this section):

- `gapplication list-apps` returns a short list (~10–20 entries) — and
  **every entry is a GNOME-core application**:
  ```
  $ gapplication list-apps
  org.gnome.Calendar
  org.gnome.Logs
  org.gnome.Zenity
  io.snapcraft.SessionAgent
  org.gnome.Characters
  org.gnome.DiskUtility
  org.gnome.font-viewer
  org.gnome.baobab
  org.gnome.seahorse.Application
  org.gnome.Totem
  org.gnome.DejaDup
  org.gnome.Nautilus
  org.gnome.clocks
  ```
  None of the user's daily-driver third-party apps (browsers, Electron
  editors, chat clients, media players) appear — even though they're
  installed, have `.desktop` files, and are reachable via `gtk-launch`.
- `gapplication action <id> quit` works for `org.gnome.Calendar` but
  fails with "no such app" for any third-party app ID.
- Blog posts and stackoverflow answers suggesting `gapplication` as the
  Linux equivalent of macOS Apple Events appear to work in their isolated
  examples but completely fail when applied to a real Ubuntu Desktop's
  installed app set.

**First seen**: 2026-05-13 on Ubuntu 24.04 GNOME Shell 46.0 Wayland during
the empirical probe for `backlog/linux-desktop-app-control.md`. Probed
against the user's 5 apps: **Zen / Cursor / Spotify / Discord /
Frpc-Desktop — coverage was 0/5 (zero), not "patchy" as initial research
had assumed**.

**Why this happens**:

`gapplication list-apps` enumerates only `.desktop` files that contain
`DBusActivatable=true`. This flag means the app implements the freedesktop
`org.freedesktop.Application` D-Bus interface — apps that opted in to
expose `Activate` / `Open` / `ActivateAction` methods over D-Bus. The
freedesktop spec defines the interface, but **adoption is essentially
zero outside GNOME core**:

- GNOME first-party apps (Nautilus, Calendar, Calculator, …) opt in.
- KDE first-party apps usually don't (they use KIO / Plasma's own bus).
- Every Electron app — Cursor, VSCode, Discord, Slack, Notion,
  Antigravity, Frpc-Desktop — doesn't.
- Every AppImage — Zen, Frpc, almost every cross-distro AppImage —
  doesn't (AppImage bundling tools don't typically inject the flag).
- Snap apps — Spotify, Firefox-snap — don't (snap confinement gets in the
  way of the bus name registration too).
- Flatpak apps — Discord-flatpak, etc. — *can* if the upstream
  `.desktop` declares it, but Flathub package maintainers rarely add it.
- Firefox / Zen / Brave / Chromium — don't.

So `gapplication` is **the right semantic model for the macOS Apple
Events analog**, but in practice it covers ~10% of a real desktop's
installed apps. The earlier backlog entry assumed "patchy good" coverage;
empirical measurement on a daily-driver host showed it's effectively
zero for third-party apps.

**Fix**:

Don't rely on `gapplication list-apps` or `gapplication action <id>
quit` as the primary mechanism on Linux. Use the hybrid stack from
`dot_config/shell/56_linux_apps.sh`:

| Task | Use this instead | Why |
|---|---|---|
| Launch any installed app | `gtk-launch <desktop-id>` (or `gio launch <path.desktop>`) | Works for any `.desktop` regardless of `DBusActivatable=` |
| Graceful quit | `pkill -TERM -f <runtime-pattern>` | Electron + Firefox honour SIGTERM as graceful quit |
| Bring to front | GNOME `window-calls` ext → `gdbus call …Activate(<WM_CLASS>)` | Compositor-side window selection; needs manual ext install |
| Media-player responsiveness | `playerctl -p <name> status` | MPRIS is the one cross-DE standard that actually has wide adoption |

**Identifying a `DBusActivatable=true` app at build-time** (useful when
deciding whether `gapplication action … quit` is worth trying):

```sh
grep -l '^DBusActivatable=true' \
  /usr/share/applications/*.desktop \
  ~/.local/share/applications/*.desktop \
  /var/lib/flatpak/exports/share/applications/*.desktop \
  ~/.local/share/flatpak/exports/share/applications/*.desktop \
  /var/lib/snapd/desktop/applications/*.desktop \
  2>/dev/null
```

If a third-party app *does* opt in (rare but possible), preferring its
`gapplication action <id> quit` over `pkill -TERM` is the cleaner path
because it goes through the app's own shutdown handler.

**Related**:

- `dot_config/shell/56_linux_apps.sh.tmpl` — the helper that implements
  the hybrid approach.
- `backlog/linux-desktop-app-control.md` → empirical findings section #1
  ("`gapplication` has 0% coverage").
- `pitfalls/linux-app-control-appimage-runtime-path.md` — the
  AppImage-specific corollary (even after sidestepping gapplication, you
  still need runtime-path patterns for AppImage apps).
- [freedesktop org.freedesktop.Application spec](https://specifications.freedesktop.org/desktop-entry-spec/desktop-entry-spec-latest.html#dbus) — the interface third-party apps don't implement.
