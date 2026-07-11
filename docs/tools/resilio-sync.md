# Resilio Sync — P2P file sync (AirDrop-style transfer + phone→NAS backup)

[Resilio Sync](https://www.resilio.com/sync/) is a peer-to-peer file-sync tool (BitTorrent-based, no cloud middleman). This repo installs it for two jobs:

- **Cross-system transfer** — drop a file in a synced folder on one machine, it appears on the others (AirDrop-style, but cross-platform and over any network).
- **Phone → NAS photo backup** — the Resilio mobile app camera-backup pushes photos into a folder that syncs to a NAS/server host running the daemon.

Opt-in via the `installResilioSync` chezmoi prompt (default off).

- **Install**:
  - **macOS** — GUI app via Homebrew cask `resilio-sync` (in `dot_config/homebrew/Brewfile.darwin.tmpl`, gated by `installResilioSync`).
  - **Linux (desktop *and* server)** — the `resilio-sync` package from Resilio's apt repo, installed by the [`resilio_sync`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/resilio_sync/tasks/main.yml) ansible role. **There is no GUI on Linux** — it runs as a daemon (binary `rslsync`) and you configure it through a WebUI on `127.0.0.1:8888`.
- **Verify**: `rslsync --help` (Linux) / open the app (macOS); `systemctl --user status resilio-sync` (Linux service).
- **Status in this repo**: opt-in via `installResilioSync=true`. On Linux the daemon is run as a **per-user** systemd service (see below), gated by the role default `resilio_sync_enable_service` (true).

---

## Platform model

| | macOS | Linux (desktop + server) |
|---|---|---|
| Form | Native GUI app (menu-bar) | Headless daemon (`rslsync`) — **no GUI** |
| Install | brew cask `resilio-sync` | apt `resilio-sync` (`resilio_sync` role) |
| Configure | In the app | WebUI `http://127.0.0.1:8888` |
| Runs as | Your user (login item) | Your user (per-user systemd service) |
| Config dir | `~/Library/Application Support/Resilio Sync/` | `~/.config/resilio-sync/` |

The Linux package being headless is *why* `ubuntu_server` is fully supported: nothing here needs a desktop.

## Linux: per-user service

The package ships both a rootful system unit (running as the `rslsync` system user) and a per-user unit (`/usr/lib/systemd/user/resilio-sync.service`). This repo **disables the system unit and runs the per-user one** so the daemon has direct access to *your* `$HOME` files — the natural fit for photo/NAS sync. This mirrors the repo's Docker-rootless pattern.

```bash
# Service lifecycle (per-user)
systemctl --user status  resilio-sync
systemctl --user restart resilio-sync
systemctl --user stop    resilio-sync

# The role runs `loginctl enable-linger $USER` so the daemon survives logout
# (important on a headless server you SSH into and then disconnect).
loginctl show-user "$USER" --property=Linger   # -> Linger=yes
```

Config and identity live in `~/.config/resilio-sync/` — **not** chezmoi-managed (it holds per-device identity/keys). Configure via the WebUI, not by hand.

## Reaching the WebUI on a headless server

The WebUI binds to loopback (`127.0.0.1:8888`) only. From your laptop, SSH-tunnel it:

```bash
ssh -L 8888:127.0.0.1:8888 user@server
# then open http://localhost:8888 in your browser
```

On first load the WebUI asks you to set a username/password and accept the EULA.

## First-run workflow

**macOS**: open Resilio Sync → accept EULA → **Add folder** (or **+ → Standard folder**) → it generates a key/link → share that with your other machines.

**Linux/headless (WebUI)**:

1. Tunnel + open `http://localhost:8888`, set WebUI login.
2. **+ → Standard folder**, pick a path (e.g. `~/Sync/photos`).
3. Click the folder → **Copy key** (or **Share** → read-write vs read-only link / QR code).
4. On the second machine (or mobile app), **+ → Enter a key or link** and paste it.

Key types: a **read-write** key lets a peer change files both ways; a **read-only** key is one-directional (good for a NAS that only *receives*). The QR code is for pairing the mobile app quickly.

## Phone → NAS photo backup recipe

1. On the NAS/server host: create a read-write Standard folder, e.g. `~/Sync/CameraBackup`, that also lives on (or is symlinked to) NAS storage.
2. Grab that folder's **read-write** key/QR from the WebUI.
3. Install the **Resilio Sync mobile app**, add the folder by scanning the QR, and enable **camera / photo backup** pointed at it.
4. Photos now sync phone → server folder → NAS automatically whenever both are online (same LAN or over the internet via Resilio's relays).

## Troubleshooting

- **WebUI won't load** — confirm the service is up (`systemctl --user status resilio-sync`) and the SSH tunnel is active; the port is `8888` on loopback.
- **`Address already in use` / port 8888 taken** — another process (or the old rootful `resilio-sync.service`) is bound. Check `sudo ss -ltnp | grep 8888`; ensure the system unit is disabled (`sudo systemctl status resilio-sync`).
- **Permission denied on synced files** — the per-user service runs as *you*, so sync folders must be readable/writable by your user. (If you ever switch back to the rootful unit, files are owned by the `rslsync` user instead.)
- **Peers don't discover each other on the LAN** — allow Resilio's ports through the firewall (it uses a listening port shown in WebUI → Preferences; LAN discovery is UDP multicast). Over the internet it falls back to Resilio relay/tracker.
- **Service didn't start after `chezmoi apply`** — on containers/hosts without a user systemd session the enable step is best-effort; start it manually once a session exists.
- **Install failed at the GPG-key / apt step (`gpg: no valid OpenPGP data found`, or a multi-minute hang)** — Resilio's CDN resolves to an IPv6 Meta/Fastly endpoint where **port 80 (`http://`) is blocked on some networks** while `https://` works. The role fetches the key and repo over `https://` for exactly this reason; if you still see it, test `curl -I --max-time 10 https://linux-packages.resilio.com/resilio-sync/key.asc` (expect `200`).

## Related

- Install mechanism overview: [tool-managers.md](../this_repo/tool-managers.md) (§ Tool index → `resilio-sync`; § Vendor apt repos → `linux-packages.resilio.com`).
- Cloud-sync alternative for one-directional cloud targets: `rclone` (managed via `devtools`).
