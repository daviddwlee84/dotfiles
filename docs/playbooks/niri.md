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
   - `resources/niri.desktop` → `/usr/local/share/wayland-sessions/niri.desktop`
     (so GDM lists **niri** as a Wayland session)
   - `resources/niri.service` + `resources/niri-shutdown.target` →
     `/etc/systemd/user/`
5. **NVIDIA tweak** (only when `/proc/driver/nvidia/version` exists): writes
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

## Related

- Role: [`dot_ansible/roles/niri/`](../../dot_ansible/roles/niri/tasks/main.yml)
- Config: [`dot_config/niri/config.kdl`](../../dot_config/niri/config.kdl)
- Other desktop apps: [Linux GUI apps](linux-gui-apps.md)
