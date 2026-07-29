# Linux GUI Apps — packaging mechanisms, this repo's strategy, and how to add a new one

Ubuntu has **five** packaging mechanisms for desktop apps. They differ in
*where binaries land*, *whether anything keeps them current*, and *how
desktop integration (icon, `.desktop`, MIME handlers) gets wired up*.

This doc:

1. lays out the five mechanisms and the trade-off matrix,
2. inventories every GUI app this repo's `gui_apps_linux` ansible role
   knows about (plus the snaps you probably installed via Ubuntu App
   Center), so you can tell at a glance which path each app is on,
3. gives a decision tree for adding a *new* app to the role.

## TL;DR — five mechanisms, one trade-off matrix

| Mechanism | Auto-update? | Install scope | Desktop integration | Sandbox |
|---|---|---|---|---|
| **`.deb` w/ apt-source postinst** | ✅ via `apt upgrade` | system-wide (`/usr/share/...`) | ✅ baked in | ❌ |
| **`.deb` w/o apt-source postinst** | ❌ manual re-deploy | system-wide | ✅ baked in | ❌ |
| **Snap** (Ubuntu App Center) | ✅ `snapd` background daemon | `/snap/<app>/<rev>/` | ✅ baked in | ✅ confined |
| **Flatpak** (Flathub) | ✅ `flatpak update` | per-user `~/.var/app/...` | ✅ baked in | ✅ confined |
| **AppImage + AppImageLauncher** | ❌ re-download | per-user `~/Applications/` | ✅ via AIL daemon | ❌ |
| Cargo / from source | ❌ via `cargo install --force` | per-user `~/.cargo/bin/` | ❌ manual `.desktop` | ❌ |
| Tarball / `.tar.xz` | ❌ pure manual | per-user (anywhere) | ❌ manual | ❌ |

The **green-checkmark `.deb` row is the gold standard** when upstream
provides it. Snap and Flatpak are the auto-update fallbacks for vendors
who don't ship `.deb` (or who want sandboxing). AppImage is the
last-mile bridge for everyone else.

## Priority order on Ubuntu

The matrix above is *what each mechanism does*. The list below is *which
to pick when you have a choice* — the explicit ordering this repo
follows when a vendor ships in multiple formats:

1. **`.deb` w/ auto apt-source** — `apt upgrade` keeps it current with zero
   sandbox overhead and native startup speed. The right answer for
   hot-path apps (editors, terminals, browsers, daily-driver tools).
   Examples: Cursor, VSCode, Chrome, Signal, 1Password, Slack.
2. **Flatpak (Flathub)** — clean sandbox, cross-distro friendly, faster
   to launch than Snap, auto-update via `flatpak update`. Right when
   `.deb` is missing or vendor only publishes on Flathub. Default
   recommendation for community-packaged apps that need confinement.
3. **Snap** — set-and-forget auto-refresh via `snapd` (4×/day, no user
   action). Acceptable for non-hot-path apps where the extra ~1-3s
   startup penalty is invisible (password manager, music player).
   Avoid for hot-path apps; the daily startup cost adds up.
4. **AppImage + AppImageLauncher** — when 1-3 are unavailable. No
   auto-update unless the bundle ships `.zsync` AND AppImageLauncher's
   update check is configured. Re-running our ansible task is the
   typical refresh path.
5. **Cargo / from-source / tarball** — last resort. Manual everything,
   no apt/snap/flatpak update path. Only when upstream really only
   ships source.

> **Why not "always Snap"?** Snap looks similar to Homebrew Cask on
> macOS but the comparison is misleading. Snap apps live in
> `/snap/<app>/<rev>/` mounted as squashfs and bring up an AppArmor
> sandbox on every launch — Firefox snap takes ~2-3s to boot on SSD
> versus ~0.3s for the `.deb`. The sandbox also breaks subtle workflows
> by default (snap Bitwarden can't read `~/.ssh` without `snap connect
> bitwarden:password-manager-service`; many snaps can't see external
> drives). For occasional-use apps these costs are invisible; for
> daily drivers (browser, IDE, terminal) they're a real annoyance.
> Snap is *fine* — it's just not the universal answer macOS users
> sometimes assume from their Cask experience. Pick by row 1-3 above.

## Inventory of GUI apps on this machine

### Ansible-managed (this repo)

| App | Mechanism | Auto-update? | Source-of-truth | Where it lives |
|---|---|---|---|---|
| **Cursor** | `.deb` (auto-adds `/etc/apt/sources.list.d/cursor.sources`) | ✅ `apt upgrade cursor` | [`gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) "Install Cursor via .deb" | `/usr/share/cursor/` |
| **VSCode** | `.deb` (auto-adds `vscode.sources`) | ✅ `apt upgrade code` | same role | `/usr/share/code/` |
| **Discord** | `flatpak` (default, recommended) OR `.deb` (no apt source) — picked by `discordChannel` chezmoi prompt | ✅ via `flatpak update` (default) / ❌ manual on `.deb` | same role | `~/.local/share/flatpak/app/com.discordapp.Discord/` (flatpak) or `/usr/share/discord/` (.deb) |
| **Steam** | Valve apt repo (`steam-launcher`), gated by `installGamingApps=true` and x86_64 | ✅ via apt for launcher/runtime packages; Steam client self-updates on launch | same role | `/usr/lib/steam/` + `/usr/share/applications/steam.desktop` |
| **Zen Browser** | AppImage in `~/Applications/`, downloaded as `zen.AppImage` but **matched by glob** `zen*.AppImage` (AppImageLauncher renames integrated copies to `zen_<md5>.AppImage`); asset picked from the `zen-browser/desktop` latest release by exact name `zen-<arch>.AppImage` | ❌ — delete every `~/Applications/zen*.AppImage` **then** re-run the role (any surviving copy counts as installed) | same role | wherever the glob currently matches; the `.desktop` is rewritten from it each apply. Profile in `~/.zen/` (shared across versions, upgrade is one-way) |
| **Alacritty** | `cargo install alacritty` | ❌ — `just upgrade-cargo` | [`devtools` role](../../dot_ansible/roles/devtools/tasks/main.yml) | `~/.cargo/bin/alacritty` |
| **AppImageLauncher** | `.deb` (PPA on 22.04, GitHub release on 24.04) | ✅ via apt | same role | system + `appimagelauncherd.service` (user) |
| **Bitwarden CLI** (`bw`) | npm via mise (gated by `installBitwarden=true`) | ❌ — `just upgrade-mise` | [`bitwarden` role](../../dot_ansible/roles/bitwarden/tasks/main.yml) | `~/.local/share/mise/...` |
| **Bitwarden Desktop** | Snap (`bitwarden`) → `.deb` fallback if `snap` unavailable; gated by `installBitwarden=true` AND `profile=ubuntu_desktop` | ✅ via `snapd` background refresh (or `apt upgrade` for fallback `.deb`) | same role | `/snap/bitwarden/current/` |
| **CopyQ** | `.deb` via stock apt (`apt install copyq`); gated by `profile=ubuntu_desktop` via tag selection in [`run_onchange_after_20_ansible_roles.sh.tmpl`](../../.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl) | ✅ via `apt upgrade` | [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) "Install CopyQ via apt" | `/usr/bin/copyq` + `/etc/xdg/autostart/com.github.hluk.copyq.desktop` |

### Manually managed (you installed these yourself, outside ansible)

| App | Mechanism | Auto-update? | How it got there | How to upgrade |
|---|---|---|---|---|
| **Spotify** | Snap (publisher `Spotify**`) | ✅ background | Ubuntu App Center | `snap refresh spotify` |
| **Firefox** | Snap (canonical default since Ubuntu 22.04) | ✅ background | preinstalled with the OS | `snap refresh firefox` |
| **btop** | Snap (kz6fittycent) | ✅ background | manual | `snap refresh btop` |
| **Frpc Desktop** | AppImage at `~/Applications/Frpc-Desktop-1.2.1.AppImage` | ❌ — manual re-download | manual drop-in | overwrite the file |
| **Clash for Windows** | tarball at `~/Documents/ClashForWindows/` ⚠️ | ❌ **DEPRECATED upstream** | extracted manually 2025 | **Migrate** — see below |

> **Clash for Windows is dead.** The original developer (Fndroid)
> publicly stopped maintenance in **2023-11** and the GitHub repo is
> archived. No new releases, no CVE patches. Migrate to one of the
> maintained forks:
>
> - [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) — active fork, ships .deb + AppImage
> - [Clash Nyanpasu](https://github.com/libnyanpasu/clash-nyanpasu) — Tauri-based GUI, AppImage + .deb
> - [Mihomo Party](https://github.com/mihomo-party-org/mihomo-party) — successor of CFW UX, AppImage + .deb
>
> All three publish `.deb` packages — drop the new app into `gui_apps_linux`
> following the [`.deb` pattern](#concrete-patterns) below and delete
> `~/Documents/ClashForWindows/` after the new one is wired up.

## Why `.deb` auto-update works (the apt-source postinst trick)

When `dpkg -i cursor_<v>_amd64.deb` runs, Cursor's package contains a
`DEBIAN/postinst` script that, on success, writes:

- `/etc/apt/sources.list.d/cursor.sources` — pointing at `https://downloads.cursor.com/aptrepo`
- `/usr/share/keyrings/anysphere.gpg` — the signing key

After that, `apt update` pulls Cursor's release index alongside Ubuntu's
own, and `apt upgrade cursor` (or generic `apt upgrade` / `just upgrade-system`)
treats it like any other apt package. The user never needs to revisit
cursor.com.

You can verify this for any installed `.deb`:

```sh
dpkg -L cursor | grep -E 'sources|keyring'
# /etc/apt/sources.list.d/cursor.sources
# /usr/share/keyrings/anysphere.gpg
```

VSCode, Chrome, Signal, 1Password, Slack, Microsoft Edge, Brave all
follow this pattern. **Discord does not** — see the next section.

## Discord auto-update — why the screenshot keeps appearing

Discord's `.deb` does **not** ship a postinst that adds an apt source:

```sh
dpkg -L discord | grep -E 'sources|keyring'
# (empty)
```

So `apt upgrade` is never aware of new Discord releases. Discord's
in-app updater detects the version mismatch, but on Linux it can't
actually invoke `dpkg` (no root) — so it pops the *"Must be your lucky
day, there's a new update!"* modal with a "Download" button that just
opens the vendor download page. You then have to manually `dpkg -i` the
new `.deb`.

Three ways out:

1. **Re-run the ansible task on demand**: `chezmoi apply` (the role
   re-fetches the latest `.deb` URL via Discord's API every apply).
   This is what we do for Cursor too, so it's consistent.
2. **Switch to Flatpak**: `flatpak install flathub com.discordapp.Discord`.
   Flatpak auto-updates via `flatpak update`. Loses some native
   integration (notifications via XDG portal, screen-share via
   PipeWire) but the upgrade story is clean.
3. **Switch to Vesktop / WebCord** (community Discord clients with
   self-update). Drift from official Discord; not recommended unless
   you're already running modded Discord.

**This repo's default is option 2 (Flatpak)** — controlled by the
`discordChannel` chezmoi prompt (`flatpak | deb | none`, default `flatpak`).
The role's flatpak path:

1. apt-installs the `flatpak` package if missing (one-time, with sudo)
2. adds the Flathub remote at user scope (no sudo)
3. installs `com.discordapp.Discord` at user scope (no sudo)

To switch from `.deb` to `flatpak` on an existing machine: set
`discordChannel = "flatpak"` in `~/.config/chezmoi/chezmoi.toml` and run
`chezmoi apply --tags gui_apps`. The two installs can coexist briefly
(different `.desktop` entries); once you've validated the Flatpak version,
`sudo apt remove discord` to clean up the old `.deb`.

## Steam — why this uses Valve's apt repo, not Flatpak/Snap

Steam is gated by `installGamingApps=true` and currently only installed on
x86_64 Ubuntu Desktop. Valve publishes an official apt repository at
`https://repo.steampowered.com/steam/`; the role installs its signing key
from `archive/stable/steam.gpg`, enables `i386`, adds the repo as deb822,
and installs `steam-launcher`.

The `i386` architecture is intentional: Steam still needs 32-bit runtime
libraries for parts of the launcher and many games. Do not hard-code old
Mesa package names from older guides (for example `libgl1-mesa-glx`) in the
role; Ubuntu 24.04 no longer ships that package. Let `steam-launcher` pull
the current dependencies and recommends.

Flathub's `com.valvesoftware.Steam` exists, but it is a community package
and explicitly not Valve's supported path. It also needs extra filesystem
overrides for libraries on non-default drives. If this repo ever adds a
`steamChannel` prompt, keep Valve apt as the default.

## Snap (Ubuntu App Center) — what's actually happening

The Ubuntu App Center is a GTK frontend for `snapd` — Canonical's
universal package manager that ships `.snap` archives from the Snap
Store. When you install **Bitwarden** or **Spotify** from App Center:

- The `.snap` file is extracted to `/snap/<app>/<rev>/` (versioned,
  read-only)
- A symlink `/snap/<app>/current` always points at the active rev
- A wrapper script at `/snap/bin/<app>` is what `$PATH` actually picks up
- A user-systemd service `snapd.refresh.service` checks for updates
  ~4× per day and applies them in the background
- Desktop integration (`/var/lib/snapd/desktop/applications/<app>.desktop`)
  is auto-generated; the snap-store daemon updates these on refresh

This means **Bitwarden Desktop and Spotify will keep themselves up to
date with no manual action** — the same way `apt upgrade` doesn't run
automatically but apt-source `.deb`s are kept current via your existing
`just upgrade-system` cadence, snaps are kept current via `snapd`'s
*always-on* refresh daemon. Different paradigm, same end result.

To inspect: `snap list`, `snap info <app>`, `snap refresh --list`
(pending updates), `snap refresh <app>` (force-refresh now), `snap
revert <app>` (rollback to previous rev — neat property of the
versioned `/snap/<app>/<rev>/` layout).

> Caveat: snaps run in a confinement sandbox, which can break power-user
> workflows (no access to `~/.ssh` by default for example). Most desktop
> apps work fine; CLI tools sometimes don't. Prefer `.deb` or apt
> when both options exist.

## AppImage + AppImageLauncher — the catch-all

When upstream ships only an AppImage (Zen Browser, Cursor's old AppImage,
many indie tools), our convention is:

1. **Download to a stable filename, but never *depend* on it**: write the file
   as `~/Applications/<app>.AppImage` (no version or hash), and guard the
   install with a **glob** (`<app>*.AppImage`), not that exact path.
   AppImageLauncher renames integrated AppImages to `<app>_<md5>.AppImage`, so
   an exact-path guard turns every apply into a fresh multi-hundred-MB
   re-download. Files like `zen-x86_64_fe71259e...AppImage` also accumulate —
   warn when the glob matches more than one instead of silently picking.
2. **Executable bit**: `mode: '0755'` in the ansible task.
3. **AppImageLauncher integration**: `appimagelauncherd.service` (user
   systemd unit, set up by our role) watches `~/Applications/`. New
   AppImages trigger a first-run modal: *"Integrate or Run once?"* —
   integrating extracts the icon, generates a `.desktop` entry under
   `~/.local/share/applications/`, and **moves the file to AppImageLauncher's
   canonical name**. Writing our own `.desktop` does *not* opt us out: AIL
   hooks execution itself through `binfmt_misc`, so any launch reaches it
   first. `ask_to_move = false` suppresses only the dialog, not the move
   (measured — see the pitfall below), and relocating the file outside
   `~/Applications` just trades the rename for a move-prompt.
4. **Re-assert desktop integration on every apply**, not only on download.
   Resolve the current AppImage path into a fact and rewrite the `.desktop`
   from it each run, so a rename self-heals instead of leaving a dangling
   `TryExec=` — which the launcher *hides* rather than reporting. If you also
   delete AIL's parallel `appimagekit_*.desktop` to keep one authority, make
   both that and `ail-cli deintegrate` `failed_when: false`: `ail-cli` does not
   exist under AppImageLauncher **Lite** (noRoot).
   [`pitfalls/appimagelauncher-renames-managed-appimage.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/appimagelauncher-renames-managed-appimage.md)
5. **Gate the desktop-integration tasks on `is not skipped`**, not just
   `is succeeded`. A task skipped by its `when:` still passes `is succeeded`,
   so a failed/skipped download will happily go on to write an icon and a
   `.desktop` whose `TryExec=` dangles — which hides the launcher entry
   instead of erroring, and leaves `failed=0` in the apply log. Pair the
   download with an explicit "no asset matched" `debug` warning too; a
   `rescue:` block cannot catch a no-op. Full story:
   [`pitfalls/ansible-folded-scalar-regex-empty-url-silent-skip.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-folded-scalar-regex-empty-url-silent-skip.md)

For our managed AppImages we write the `.desktop` entry ourselves in the same
ansible task so the app is searchable *immediately*, without waiting for a
first launch — see Zen Browser. This buys instant availability and a stable
`.desktop` id for `linux_app_register --desktop=`; it does **not** prevent
AppImageLauncher from integrating and renaming the file later, which is why the
role re-asserts the entry every apply. For AppImages you drop manually (Frpc
Desktop), let the modal handle it.

To check the daemon: `systemctl --user status appimagelauncherd`.
Manual integration: `ail-cli integrate ~/Applications/foo.AppImage`.

## Adding a new GUI app to `gui_apps_linux`

```
Does upstream publish a .deb?
├─ YES → Does the .deb add an apt source (check `dpkg -L <pkg> | grep sources` after install)?
│        ├─ YES → use the .deb. Ansible installs once, apt keeps current. ★ best path
│        └─ NO  → use the .deb anyway, BUT add a refresh hook to
│                 `scripts/upgrade_tools.sh` so `just upgrade-system`
│                 re-fetches latest. (Discord pattern.)
│
├─ NO ── Does upstream publish on Snap or Flatpak with FIRST-PARTY support?
│        ├─ Official Snap → use snap (community.general.snap module).
│        │                 Cleanest auto-update on Ubuntu, but confined.
│        ├─ Official Flathub → use flatpak (community.general.flatpak module).
│        │                    Cross-distro friendly, also confined.
│        └─ Community-only → skip; AppImage probably more reliable.
│
└─ Only AppImage / tarball?
   ├─ AppImage → drop in ~/Applications/ as <app>.AppImage. AIL integrates.
   └─ tarball  → ~/Applications/<app>/ + wrapper script + manual .desktop.
                 ⚠️ Last resort — no auto-update path, manual everything.
```

### Concrete patterns

**`.deb` pattern** — see "Install Cursor via .deb" in
[`gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml).
Two-step:

1. `ansible.builtin.uri` — fetch vendor's API to resolve the latest
   `.deb` URL (return JSON, parse `debUrl` or similar field).
2. `ansible.builtin.get_url` — download the `.deb`, with `force: true`
   (overwrite stale files from prior apply) and `until: cursor_dl is
   succeeded` + `retries: 4` + `delay: 5` (GFW-region CDN drops).
3. `ansible.builtin.apt: deb=<path>` — install. Postinst handles apt
   source if vendor ships one.
4. Wrap the whole block in `rescue:` that prints a manual-fallback URL.

**AppImage pattern** — see "Install Zen Browser AppImage" in the same
file. Three-step:

1. `ansible.builtin.uri` — GitHub releases API (or vendor equivalent)
   to resolve the asset URL.
2. `selectattr('name', 'match', '^<prefix>-<arch>\\.AppImage$')` filter
   to pick the right asset for `target_architecture` (already normalized
   to `x86_64` / `aarch64` by the `Set target_architecture from dpkg` task
   in [`linux.yml`](../../dot_ansible/playbooks/linux.yml)).
3. `ansible.builtin.get_url` to `~/Applications/<app>.AppImage` with
   `mode: '0755'` and a stable filename.
4. Write a `.desktop` entry under `~/.local/share/applications/` using
   `ansible.builtin.copy` with a `content:` literal — the file gets
   merged into the system menu via `update-desktop-database`.

**Snap pattern** — none yet in this repo. Template:

```yaml
- name: Install Bitwarden Desktop via Snap
  community.general.snap:
    name: bitwarden
    state: present
    classic: false   # most apps are confined; set true only when vendor docs say so
  become: true
```

**Flatpak pattern** — none yet. Template:

```yaml
- name: Install Discord via Flatpak (instead of .deb)
  community.general.flatpak:
    name: com.discordapp.Discord
    state: present
    remote: flathub  # add `community.general.flatpak_remote` first if missing
    method: user     # per-user install; `system` requires root
```

Always add a `rescue:` block that points the user at the manual
fallback URL (cursor.com / discord.com / GitHub release page) so a
failed automated install isn't a dead end.

## Controlling installed apps from the shell

The role installs apps; `dot_config/shell/56_linux_apps.sh.tmpl` controls
them. Linux counterpart to the macOS `app-*` helpers in
`dot_config/shell/54_macos_apps.sh.tmpl` — **same public function names**
(`appquit` / `applaunch` / `appactivate` / `apprestart` / `apprunning` /
`applist` / `appresponsive`) so users get cross-platform muscle memory.
The `tv linux-apps` channel mirrors `tv mac-apps`.

### Coverage on Wayland GNOME (no compositor extension)

| Verb | Linux backend | Fidelity |
|---|---|---|
| `applaunch NAME` | `gtk-launch <desktop-id>` (no `DBusActivatable=true` required) | ✓ works for any `.desktop` file |
| `apprunning NAME` | `pgrep -f <pattern>` (override or auto-derived) | ✓ silent boolean |
| `appquit NAME` | `pkill -TERM -f <pattern>` | ✓ Electron + Firefox quit gracefully on SIGTERM |
| `apprestart NAME` | quit + poll-gone (≤15s) + launch | ✓ launches even if not running |
| `appactivate NAME` | D-Bus → GNOME `window-calls` ext; fallback `gtk-launch` | ⚠ full focus only with extension installed |
| `applist [--pids\|--all]` | registry + `.desktop` scan, pgrep each | ⚠ "managed apps that are alive" — not every window |
| `appresponsive NAME [T]` | `playerctl -p <mpris>` for media apps; degrades to `apprunning` | ⚠ MPRIS-only; no Linux analog to macOS Apple Events |

### Why `gapplication` alone doesn't work

The freedesktop `org.freedesktop.Application` D-Bus interface is the
semantic match to macOS Apple Events — apps expose `quit` / `activate` /
etc. and `gapplication action <id> quit` calls them. **In practice, almost
no third-party app sets `DBusActivatable=true` in its `.desktop` file**:
empirically, on a daily-driver Ubuntu 24.04 Wayland session,
`gapplication list-apps` returned 13 entries — *all GNOME-core* (Calendar,
Logs, Nautilus, …). Zero of the user's Zen / Cursor / Spotify / Discord /
Frpc-Desktop showed up. See
[`pitfalls/linux-app-control-gapplication-zero-coverage.md`](../../pitfalls/linux-app-control-gapplication-zero-coverage.md).

Hybrid pivot: launch via `gtk-launch` (works for any `.desktop` file
regardless of `DBusActivatable`); quit via `pkill -TERM` on a runtime
pattern; focus via the optional `window-calls` GNOME extension.

### Override file: `~/.config/shell/linux-apps.conf`

Not auto-stubbed (mirrors `~/.shellrc.secrets` rule — empty-file footgun).
Helper sources it if present. Register apps with `linux_app_register`:

```sh
# Cursor — apt install at /usr/share/cursor/cursor (NOT the AppImage residue)
linux_app_register Cursor \
  --desktop=cursor \
  --pkill='^/usr/share/cursor/cursor( |$)' \
  --wm-class=Cursor

# Discord — apt install; ignore the Flatpak duplicate
linux_app_register Discord \
  --desktop=discord \
  --pkill='^/usr/share/discord/Discord( |$)' \
  --wm-class=discord

# Spotify — snap-confined, MPRIS-aware
linux_app_register Spotify \
  --desktop=spotify_spotify \
  --pkill='^/snap/spotify/[^/]+/usr/share/spotify/spotify' \
  --wm-class=spotify \
  --mpris=spotify

# Zen Browser — AppImage, runtime path != .desktop Exec
linux_app_register Zen \
  --desktop=zen-browser \
  --pkill='\.mount_.+/zen($| )' \
  --wm-class=zen

# Frpc-Desktop — AppImage, runtime path drifts on re-download
linux_app_register Frpc-Desktop \
  --desktop=appimagekit_557220393761292184db845cd26816c3-Frpc-Desktop \
  --pkill='\.mount_.+/frpc-desktop($| )' \
  --wm-class=Frpc-Desktop

# ClashForWindows — manually-placed Electron app, NO .desktop file.
# Use --exec= for the launch path; helper prefers --exec over --desktop.
linux_app_register CFW \
  --exec='~/Documents/ClashForWindows/cfw' \
  --pkill='^/home/.+/Documents/ClashForWindows/cfw' \
  --wm-class='Clash for Windows'
```

The `--exec=` flag covers apps with no `.desktop` (manually-placed
Electron / hand-built binaries). The flag value is passed through `eval`
to expand `~` and `$HOME`, and is executed via `setsid -f sh -c …` so
the parent shell stays clean.

`linux_app_register --list` prints the current registry; `--help` prints
flag reference.

**When to override vs let auto-derivation handle it**:

- **Always override** for AppImage, Snap, and Flatpak apps. AppImage
  runtime binary lives at `/tmp/.mount_<hash>/<inner>`, not the
  `.desktop` `Exec=` path — `pkill` on the `Exec=` path only hits the
  launcher wrapper. See
  [`pitfalls/linux-app-control-appimage-runtime-path.md`](../../pitfalls/linux-app-control-appimage-runtime-path.md).
- **Override when an app has multiple `.desktop` entries** (Zen with 4
  AppImage residues, Cursor with AppImage residue + apt install, Discord
  with apt + Flatpak both installed). Auto-derivation picks latest
  mtime, which may not be the one that's actually running.
- **Skip override** for clean apt-installed apps (their `Exec=` matches
  the runtime path 1:1) — auto-derivation handles them correctly.

### GNOME `window-calls` extension — manual install

The helper detects the extension at first `appactivate` call. Without it,
`appactivate` falls back to `applaunch`, which re-focuses for
single-instance apps like Electron + Firefox but isn't reliable for all
apps. Install once per host:

```sh
# Download from GitHub releases or extensions.gnome.org
# https://github.com/ickyicky/window-calls (or hseliger/window-calls-extended
# for GNOME 45+ if upstream is stale)
gnome-extensions install ~/Downloads/window-calls@domandoman.xyz.zip
gnome-extensions enable window-calls@domandoman.xyz
```

**Wayland sessions need a logout + login** for the extension to activate
(no `Alt+F2 r` reload like X11). The user-consent dialog on GNOME 46+
can't be suppressed, so this isn't ansible-automatable.

### Known limits (mirror the backlog)

- **No analog to macOS Apple Events' `with timeout`** for non-MPRIS apps.
  `appresponsive` for Electron / Firefox / native GTK apps degrades to
  `apprunning` with a stderr note.
- **No "hide windows" verb** (mac-apps Alt+H has no Linux equivalent
  without compositor IPC; deliberately omitted from `tv linux-apps`).
- **`applist` is "registered + auto-derived running apps"**, not "every
  GUI window". Auto-discovery filters to `.desktop` entries whose `Exec=`
  is an absolute path (skips Flatpak/AppImage wrappers that would match
  too loosely).
- **Compositor support is GNOME Wayland only.** KDE / Sway / Hyprland
  paths aren't wired — see `backlog/linux-desktop-app-control.md` for
  the deferred matrix if a second compositor joins the fleet.

## Cross-references

- [`docs/tools/appimage.md`](../tools/appimage.md) — AppImageLauncher install paths, `ail-cli`, libfuse2 / AppArmor gotchas on Ubuntu 24.04.
- [`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) — the install-vs-upgrade split: why `chezmoi apply` doesn't bump versions, what `just upgrade-*` covers, where each package manager fits in.
- [`dot_ansible/roles/gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) — the actual ansible role, with the patterns you'd copy when adding a new app.
- [`backlog/linux-desktop-app-control.md`](../../backlog/linux-desktop-app-control.md) — design history for the `app-*` helpers, options considered, and deferred follow-ups (KDE / Sway / Hyprland).
