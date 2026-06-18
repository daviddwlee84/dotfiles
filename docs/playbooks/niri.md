# niri compositor (opt-in)

[niri](https://github.com/niri-wm/niri) is a scrollable-tiling Wayland
compositor. It is **not** in the Ubuntu 24.04 apt repos (it lands in 25.04+),
so this repo builds it from source via a dedicated ansible role and ships a
curated starter config.

Everything here is gated behind `installNiri=true` on the **`ubuntu_desktop`**
profile (no Wayland on macOS; no GUI on `ubuntu_server`).

## What gets installed

The [`niri`](../../dot_ansible/roles/niri/tasks/main.yml) role (tag: `niri`,
Debian + x86_64 only):

1. **Build deps** via apt: `gcc clang libudev-dev libgbm-dev libxkbcommon-dev
   libegl1-mesa-dev libwayland-dev libinput-dev libdbus-1-dev libsystemd-dev
   libseat-dev libpipewire-0.3-dev libpango1.0-dev libdisplay-info-dev`.
2. **Source checkout** of `niri_ref` (default `v26.04`, a released CalVer tag —
   bump it in [`defaults/main.yml`](../../dot_ansible/roles/niri/defaults/main.yml)
   to upgrade) into `~/.cache/niri-build`.
3. **`cargo build --release --locked`** (never `--all-features` — some are
   dev-only and leak memory).
4. **Install artifacts** (sudo):
   - `target/release/niri` → `/usr/local/bin/niri`
   - `resources/niri-session` → `/usr/local/bin/niri-session`
   - `resources/niri.desktop` → **both** `/usr/local/share/wayland-sessions/` and
     `/usr/share/wayland-sessions/` (so GDM lists **niri** regardless of which dir
     its greeter scans; de-duped by XDG precedence so only one entry shows)
   - `resources/niri.service` + `resources/niri-shutdown.target` →
     `/etc/systemd/user/`
5. **Desktop usability** (sudo): so the empty-screen first launch isn't a dead end —
   - `apt install fuzzel` — the `Mod+D` app launcher referenced in `config.kdl`.
   - symlink `~/.cargo/bin/alacritty` → `/usr/local/bin/alacritty` so the `Mod+T`
     terminal is findable on the GDM/systemd session PATH (alacritty is cargo-built
     by `gui_apps_linux` into `~/.cargo/bin`, which is **not** on that PATH). Other
     GUI apps (Zen AppImage, VSCode/Cursor/Discord `.deb`) use absolute paths or
     `/usr/bin`, so they need no such fix and just show up in fuzzel.
6. **NVIDIA tweak** (only when `/proc/driver/nvidia/version` exists): writes
   `/etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json`
   with `GLVidHeapReuseRatio=0` so the driver doesn't hoard VRAM in Wayland
   compositors (upstream-recommended).

User config lives at `~/.config/niri/config.kdl`, managed by chezmoi from
[`dot_config/niri/config.kdl`](../../dot_config/niri/config.kdl) (deployed only
when `installNiri=true`). niri also writes its own default config on first
launch if the file is absent.

Idempotency: the role compares the installed `niri --version` against
`niri_ref` and only rebuilds on mismatch.

## Rebuild / upgrade

Install-only by design (like every role here). To upgrade:

1. Bump `niri_ref` in the role defaults.
2. Re-run the role:

   ```bash
   cd ~/.ansible
   ansible-playbook -i inventories/localhost.ini playbooks/linux.yml \
     --tags niri --ask-become-pass
   ```

To force a clean rebuild, delete `~/.cache/niri-build` first.

## NVIDIA notes

This repo's reference machine is an **RTX 3090 (primary) + AMD (secondary)**.
Modern NVIDIA drivers (`nvidia-drm modeset` on by default in 580+) run niri out
of the box; the VRAM application-profile above is the only NVIDIA-specific tweak
niri upstream recommends.

niri auto-selects the primary GPU. On multi-GPU boxes you can pin the render
device in `config.kdl`:

```kdl
debug {
    render-drm-device "/dev/dri/renderD128"
}
```

Find the right node with `ls -l /dev/dri/by-path/` or `niri msg outputs`.

## noRoot

niri needs sudo for the apt deps, `/usr/local`, and `/etc/systemd/user`. Under
`noRoot` the run-script passes `niri_no_root=true` and the role no-ops with a
debug note rather than building a binary it can't install.

## Verifying

```bash
niri --version                                   # built + on PATH
niri validate                                    # ~/.config/niri/config.kdl is valid
ls /usr/local/share/wayland-sessions/niri.desktop  # GDM can see the session
```

Then log out and pick **niri** from the GDM session menu (gear icon, bottom
right). It coexists with GNOME / i3 — niri is just another session option.

## First login & daily use

At the GDM login screen, click your user, then the **gear icon at the bottom-right**
of the password screen and pick **Niri**. (That gear lists every session — e.g.
`i3`, `i3 (with debug log)`, `Niri`, `Ubuntu` (default = GNOME Wayland),
`Ubuntu on Xorg`. It is *not* on the first page — easy to miss.)

niri starts as an **empty black screen** — no panel, no wallpaper by default. Drive
it with keybinds (`Mod` = the **Super / Windows** key):

| Key | Action |
|---|---|
| `Mod+Shift+/` | **Show the full hotkey overlay — press this first** |
| `Mod+T` | Terminal (alacritty) |
| `Mod+D` | App launcher (fuzzel) |
| `Mod+H`/`J`/`K`/`L` or arrows | Move focus |
| `Mod+Shift+H`/`J`/`K`/`L` | Move window / column |
| `Mod+1`..`5` | Switch workspace |
| `Mod+Q` | Close window |
| `Mod+R` | Cycle column width |
| **`Mod+Shift+E` then `Enter`** | **Quit niri → back to GDM (escape hatch)** |

To return to GNOME/i3: `Mod+Shift+E`, confirm with `Enter`, then pick another
session from the GDM gear menu.

## Autostart: which GUI apps launch under niri?

niri's `niri.service` declares `Wants=xdg-desktop-autostart.target`, so niri **does**
run XDG autostart entries (`/etc/xdg/autostart/*.desktop` + `~/.config/autostart/*.desktop`)
— but systemd's xdg-autostart generator honors each entry's `OnlyShowIn=` / `NotShowIn=`
against `$XDG_CURRENT_DESKTOP`, which niri sets to `niri`. So:

- Entries marked `OnlyShowIn=GNOME;` (on Ubuntu that's the majority — ~25 of ~39 in
  `/etc/xdg/autostart/` on the reference box) **only run under the GNOME "Ubuntu"
  session**, never under niri.
- Generic entries (no `OnlyShowIn`, or one that lists niri) **do** start under niri.
- **i3** (X11) does *not* pull `xdg-desktop-autostart.target` at all — it autostarts
  via `exec` / `exec_always` lines in the i3 config, so by default runs none of these.

So "do my autostart apps only start in the Ubuntu default session?" → the
**GNOME-gated** ones, yes. The portable way to start something under niri is
`spawn-at-startup "…"` in `config.kdl` (already used for the polkit agent), not the
GNOME-only XDG autostart entry.

## Troubleshooting

- **niri not in the GDM session list** → it's behind the **gear icon** on the
  password screen, not the first page. The role installs the `.desktop` to **both**
  `/usr/local/share/wayland-sessions/` and `/usr/share/wayland-sessions/` so GDM sees
  it regardless of which it scans. If you applied an older revision, copy it across
  and `sudo systemctl restart gdm3` to make the greeter rescan.
- **`Mod+T` does nothing (no terminal opens)** → alacritty is cargo-built by
  `gui_apps_linux` into `~/.cargo/bin/alacritty`, which is **not** on the niri/systemd
  session PATH (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:…`). The niri role
  now symlinks it onto the PATH automatically; manual fallback:
  `sudo ln -sf ~/.cargo/bin/alacritty /usr/local/bin/alacritty`. Same caveat for any
  other `~/.cargo/bin` or `~/.local/bin` tool you `spawn` from `config.kdl`.
- **`Mod+D` does nothing** → fuzzel launcher missing. The role installs it now;
  manual fallback: `sudo apt install -y fuzzel`.
- **NVIDIA + Wayland** → Ubuntu's `/usr/lib/udev/rules.d/61-gdm.rules` disables GDM
  Wayland only for NVIDIA driver **< 470**; 470+ (this box runs 580) keeps Wayland
  enabled, so niri is selectable. The role's VRAM application-profile is the only
  extra NVIDIA tweak.
- **`[…] RDSEED32 is broken. Disabling …` at boot** → benign CPU errata notice from
  the kernel; nothing to do with niri.

## Related

- Role: [`dot_ansible/roles/niri/`](../../dot_ansible/roles/niri/tasks/main.yml)
- Config: [`dot_config/niri/config.kdl`](../../dot_config/niri/config.kdl)
- Other desktop apps: [Linux GUI apps](linux-gui-apps.md)
