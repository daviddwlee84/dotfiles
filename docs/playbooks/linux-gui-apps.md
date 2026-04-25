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
| **Zen Browser** | AppImage at `~/Applications/zen.AppImage` (stable filename, no version suffix) | ❌ — re-run ansible task | same role | `~/Applications/zen.AppImage` |
| **Alacritty** | `cargo install alacritty` | ❌ — `just upgrade-cargo` | [`devtools` role](../../dot_ansible/roles/devtools/tasks/main.yml) | `~/.cargo/bin/alacritty` |
| **AppImageLauncher** | `.deb` (PPA on 22.04, GitHub release on 24.04) | ✅ via apt | same role | system + `appimagelauncherd.service` (user) |
| **Bitwarden CLI** (`bw`) | npm via mise (gated by `installBitwarden=true`) | ❌ — `just upgrade-mise` | [`bitwarden` role](../../dot_ansible/roles/bitwarden/tasks/main.yml) | `~/.local/share/mise/...` |
| **Bitwarden Desktop** | Snap (`bitwarden`) → `.deb` fallback if `snap` unavailable; gated by `installBitwarden=true` AND `profile=ubuntu_desktop` | ✅ via `snapd` background refresh (or `apt upgrade` for fallback `.deb`) | same role | `/snap/bitwarden/current/` |

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

1. **Stable filename**: drop the file at `~/Applications/<app>.AppImage`
   (no version or hash in the name). Re-runs of the ansible task just
   overwrite it. Files like `zen-x86_64_fe71259e...AppImage` (old hash
   suffix in filename) are the wrong shape — they accumulate forever.
2. **Executable bit**: `mode: '0755'` in the ansible task.
3. **AppImageLauncher integration**: `appimagelauncherd.service` (user
   systemd unit, set up by our role) watches `~/Applications/`. New
   AppImages trigger a first-run modal: *"Integrate or Run once?"* —
   integrating extracts the icon, generates a `.desktop` entry under
   `~/.local/share/applications/`, and (optionally) moves the file to
   AppImageLauncher's canonical location.

For our managed AppImages we usually skip the modal by writing the
`.desktop` entry ourselves in the same ansible task — see Zen Browser.
For AppImages you drop manually (Frpc Desktop), let the modal handle it.

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

## Cross-references

- [`docs/tools/appimage.md`](../tools/appimage.md) — AppImageLauncher install paths, `ail-cli`, libfuse2 / AppArmor gotchas on Ubuntu 24.04.
- [`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) — the install-vs-upgrade split: why `chezmoi apply` doesn't bump versions, what `just upgrade-*` covers, where each package manager fits in.
- [`dot_ansible/roles/gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) — the actual ansible role, with the patterns you'd copy when adding a new app.
