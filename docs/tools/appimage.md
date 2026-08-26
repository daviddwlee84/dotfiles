# AppImage & AppImageLauncher on Ubuntu

> AppImage is **one of five** GUI-app packaging mechanisms on Ubuntu (alongside `.deb`, Snap, Flatpak, and from-source). For the cross-mechanism comparison, the inventory of which app uses which, and the decision tree for picking a mechanism when adding a new GUI app to this repo's ansible role, see [`docs/playbooks/linux-gui-apps.md`](../playbooks/linux-gui-apps.md). This page is the AppImage-specific deep dive.

[AppImage](https://appimage.org/) is a single-file app format for Linux: download, `chmod +x`, run. No root, no install step, no dependencies beyond the host's `libc` and `libfuse2`. The format is how Cursor, Obsidian, Joplin, Bitwarden Desktop, and many AI / markdown / media tools ship their Linux builds.

The gap is desktop integration: a bare `~/Applications/foo.AppImage` doesn't show up in the GNOME/KDE launcher, has no `.desktop` entry, and doesn't get picked up by `xdg-open`. That's where **[AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher)** comes in — a system daemon that watches a directory for AppImages and auto-integrates them (icon extraction, `.desktop` generation, optional move into a canonical location, optional update-via-delta).

This repo installs AppImageLauncher on `ubuntu_desktop` machines via the [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) Ansible role. This doc covers the *why*, the three install paths, and the two footguns you'll hit on current Ubuntu.

## Why AppImageLauncher vs bare AppImages vs `appimaged`

| Approach | Desktop menu? | Auto-updates? | No root? | Notes |
|---|---|---|---|---|
| Bare `chmod +x ./foo.AppImage` | No | No | Yes | Fine for one-offs; nothing shows in launcher. |
| [`appimaged`](https://github.com/probonopd/go-appimage) daemon | Yes | Yes (via zsync) | Yes | Watches dirs and writes `.desktop` entries. Less actively maintained; no first-run prompt. |
| **AppImageLauncher** (this repo) | Yes | Yes (opt-in) | Yes (Lite) | First-run modal asks "Integrate or Run once?", stores integrated AppImages in `~/Applications/`, handles removal cleanly. |

The **first-run prompt** is the real win: double-click an AppImage and AppImageLauncher asks whether to install it system-wide (move to `~/Applications/`, generate `.desktop` + icon + MIME handlers) or run once and delete. Makes AppImages feel like regular apps without locking you into yet another store.

## Install paths

The Ansible role tries these in order, falling through on failure:

### 1. Ubuntu PPA (preferred on 20.04 / 22.04 LTS)

```bash
sudo add-apt-repository ppa:appimagelauncher-team/stable
sudo apt update
sudo apt install appimagelauncher
```

Packaged as `appimagelauncher` (system daemon + `.desktop` hook + `ail-cli`). Integrates via `/usr/share/applications/appimagelauncher.desktop` and the XDG MIME handler for `application/x-appimage`.

### 2. GitHub `.deb` fallback (needed on 24.04 "noble")

The PPA [has no release for Ubuntu 24.04](https://github.com/TheAssassin/AppImageLauncher/issues) as of 2026; maintainership has stalled. The latest `.deb` from the GitHub releases page still installs cleanly on noble:

```bash
ARCH=$(dpkg --print-architecture)   # amd64 / arm64
curl -fsSL "https://api.github.com/repos/TheAssassin/AppImageLauncher/releases/latest" \
  | jq -r --arg a "$ARCH" '.assets[] | select(.name | test("^appimagelauncher_.*_\($a)\\.deb$")).browser_download_url' \
  | xargs -I{} curl -fSL -o /tmp/appimagelauncher.deb {}
sudo apt install -y /tmp/appimagelauncher.deb
```

The Ansible role automates this block via `ansible.builtin.uri` against the GitHub API + `ansible.builtin.apt: deb:`.

### 3. AppImageLauncher **Lite** (no root, user-level)

Lite is AppImageLauncher shipped as an AppImage itself — integrates itself into `~/.config/autostart`, `~/.local/share/applications`, `~/.local/share/icons`. Useful on locked-down machines where you can't `sudo`.

```bash
mkdir -p ~/Applications
curl -fsSL "https://api.github.com/repos/TheAssassin/AppImageLauncher/releases/latest" \
  | jq -r --arg a "$(uname -m)" '.assets[] | select(.name | test("^appimagelauncher-lite-.*-\($a)\\.AppImage$")).browser_download_url' \
  | xargs -I{} curl -fSL -o ~/Applications/appimagelauncher-lite.AppImage {}
chmod +x ~/Applications/appimagelauncher-lite.AppImage
~/Applications/appimagelauncher-lite.AppImage install   # one-time integration
```

The Ansible role runs this when `gui_apps_linux_no_root=true` is passed (automatically set by `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` in the `noRoot` chezmoi profile).

## `ail-cli` — scripted integration

The system daemon provides `ail-cli` for headless integration. Useful for provisioning scripts that drop AppImages into `~/Applications/` and want them to appear in the launcher without a double-click.

```bash
ail-cli integrate ~/Applications/Cursor.AppImage
ail-cli list-integrated
ail-cli deintegrate ~/Applications/Cursor.AppImage
```

Lite does not ship `ail-cli`; use the GUI first-run prompt or manually `chmod +x` and double-click.

## Recipes

### Cursor (when the `.deb` install misbehaves)

The [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) role installs Cursor via the official `.deb` from `cursor.com/api/download?platform=linux-x64`. If that URL ever changes or returns a broken package, the manual AppImage flow is:

```bash
mkdir -p ~/Applications
# Download the latest AppImage from https://cursor.com/download ("Download AppImage" link)
mv ~/Downloads/Cursor-*.AppImage ~/Applications/Cursor.AppImage
chmod +x ~/Applications/Cursor.AppImage
ail-cli integrate ~/Applications/Cursor.AppImage
# (or double-click to trigger the first-run prompt)
```

Editor user settings (`settings.json`, `keybindings.json`) are independent of install method — chezmoi manages them via [`.chezmoitemplates/editor/`](../../.chezmoitemplates/editor/) regardless of whether Cursor came from `.deb` or AppImage.

### Zen Browser (installed automatically)

The [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) role downloads the latest `zen-<arch>.AppImage` from [`zen-browser/desktop`](https://github.com/zen-browser/desktop/releases) to `~/.local/opt/zen/zen.AppImage` and writes a stable `~/.local/share/applications/zen-browser.desktop` + SVG icon. A one-time migration moves the newest legacy `~/Applications/zen*.AppImage` into that managed path.

Writing our own `.desktop` alone does **not** exempt Zen from AppImageLauncher — AIL hooks execution through `binfmt_misc`, while its daemon watches `~/Applications`. The role now addresses both paths: Zen lives outside the watched directories and its desktop command exports the upstream-supported `APPIMAGELAUNCHER_DISABLE=1`, which the binfmt interpreter checks before dispatch. Stale `appimagekit_*Zen*.desktop` and matching AIL icons are removed once. The earlier rename-loop measurements remain documented in [`pitfalls/appimagelauncher-renames-managed-appimage.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/appimagelauncher-renames-managed-appimage.md).

To upgrade: delete **every** `~/Applications/zen*.AppImage` — not just the stable name, since an integrated copy also counts as installed — then re-run `just apply-ubuntu_desktop`. Or drop a newer AppImage over whichever file is currently there.

### Obsidian / Bitwarden Desktop / Joplin

Same pattern: drop AppImage in `~/Applications/`, integrate with `ail-cli` or the first-run prompt. These apps self-update via AppImage delta (AppImageLauncher handles the update prompt too).

## Troubleshooting

### `libfuse.so.2: cannot open shared object file`

Ubuntu 22.04+ dropped `libfuse2` from the default install. AppImages compiled against fuse 2 fail with:

```plain
dlopen(): error loading libfuse.so.2
AppImages require FUSE to run.
```

Fix:

```bash
sudo apt install libfuse2
```

The Ansible role installs `libfuse2` unconditionally on `ubuntu_desktop` so this never bites on a fresh machine. If you're bootstrapping outside the role, remember the `libfuse2t64` transitional package on 24.04 — install `libfuse2` (not `libfuse3`).

### AppArmor blocks sandboxed AppImages on 24.04

Ubuntu 24.04 enabled the `unprivileged_userns_restriction` AppArmor profile, which breaks the Electron / Chromium sandbox inside AppImages (Cursor, VSCode, Obsidian, any Chromium-based tool). Symptom: the app window never appears, logs show `SUID sandbox helper binary was found, but is not configured correctly`.

Two fixes, pick one:

1. **Per-app `--no-sandbox`** (easy, slightly worse isolation):

   ```bash
   ~/Applications/Cursor.AppImage --no-sandbox
   ```

   For integrated apps, edit the generated `~/.local/share/applications/appimagekit-<hash>-Cursor.desktop` and append `--no-sandbox` to the `Exec=` line.

2. **Allow unprivileged userns globally** (better isolation, needs root):

   ```bash
   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
   # Persist:
   echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/60-apparmor-namespace.conf
   ```

   This relaxes the sandbox restriction for *all* user namespaces, not just Electron, so treat it as a deliberate trade-off.

### `.desktop` entry points at an old AppImage hash

AppImageLauncher names integrated desktop files `appimagekit-<hash>-<name>.desktop`, with `<hash>` derived from the AppImage binary. Updating an AppImage in-place (e.g. via its own updater) leaves a stale hash. Fix:

```bash
ail-cli deintegrate ~/Applications/Foo.AppImage
ail-cli integrate   ~/Applications/Foo.AppImage
update-desktop-database ~/.local/share/applications
```

## See also

- [`dot_ansible/roles/gui_apps_linux/tasks/main.yml`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) — the install role
- [`.chezmoitemplates/editor/`](../../.chezmoitemplates/editor/) — editor settings overlay that lands inside Cursor/VSCode/Antigravity regardless of install method
- [AppImageLauncher upstream](https://github.com/TheAssassin/AppImageLauncher)
- [AppImage format docs](https://docs.appimage.org/)
- [Ubuntu 24.04 AppArmor changes](https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890#unprivileged-user-namespace-restrictions-15)
