# GPU driver (NVIDIA proprietary) — drift, upgrades, and the iGPU

Sysadmin question for a **GPU workstation**: **why did `nvidia-smi` suddenly
stop working when nothing changed, and how do I stop a background updater from
doing it again mid-training?**

This page documents the `nvidia-driver-drift-check` helper, the
`52unattended-upgrades-local` blacklist, and the display topology of this box.
Sibling of [hardware.md](hardware.md) one layer up at the driver, and of
[scheduled-jobs.md](scheduled-jobs.md) (which is what fired the upgrade).

> Linux + NVIDIA proprietary driver only. Nouveau and AMD-only boxes are
> unaffected by everything on this page.

## The failure mode in one table

The proprietary NVIDIA driver is **two halves that must agree**, and only one
of them can be replaced while the machine is running:

| | userspace (`libcuda.so`, `libnvidia-ml.so`) | kernel module (`nvidia.ko`) |
|---|---|---|
| What it is at runtime | **files** on disk, mmap'd per process | **code** in the kernel's address space |
| Multiple versions at once | ✅ yes — each process maps its own | ❌ no — one instance, owns the PCI device |
| What `apt upgrade` does | `unlink` + create new. unlink drops the **name**; the inode lives as long as a process maps it | nothing — the loaded module is untouched |
| How to change it | nothing needed, new processes pick up the new file | `rmmod`, which needs refcount **0** |

So an upgrade is **invisible to every process already running** and
**fatal to every process started afterwards**:

```
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 580.173
```

CUDA's `cuInit` returns **804** (`CUDA_ERROR_COMPAT_NOT_SUPPORTED_ON_DEVICE` —
not 803, which is `CUDA_ERROR_SYSTEM_DRIVER_MISMATCH`).

**The only fix is a reboot.** There is no "reload the module" path on a box
whose display is driven by that same GPU — Xorg, gnome-shell, mutter and every
GPU-accelerated app hold `/dev/nvidia*` open, so `modprobe -r nvidia` returns
`Module nvidia is in use` with a refcount in the hundreds.

### The asymmetry that surprises people

Going **backwards** does *not* need a reboot. Pointing a new process at the
*old* userspace makes it agree with the still-loaded old module:

```bash
# temporary, per-process, nothing installed system-wide
mkdir -p /tmp/nvshim && cd /tmp/nvshim
apt-get download nvidia-utils-580=<OLD-VERSION> libnvidia-compute-580=<OLD-VERSION>
for f in *.deb; do dpkg-deb -x "$f" root/; done
LD_LIBRARY_PATH=$PWD/root/usr/lib/x86_64-linux-gnu root/usr/bin/nvidia-smi
```

This restores `nvidia-smi` and lets new CUDA processes start, without touching
the running job. It does **not** fix OpenGL/EGL/Vulkan (the shim has no
`libGLX_nvidia`/`libEGL_nvidia`) and `nvtop` silently degrades to showing only
the iGPU. Treat it as a monitoring stopgap, not a fix — every process started
against it pins another deleted inode and extends the window in which you
can't reboot.

> Old versions disappear from the archive pool quickly. `snapshot.ubuntu.com`
> is the reliable source once `apt-get download <pkg>=<old>` starts 404-ing.
>
> **Tear the shim down the moment `/proc/driver/nvidia/version` changes**, not
> "after the reboot" — once the module is new, the shim creates the mismatch in
> the opposite direction and the errors look identical.

## Drift detection

`nvidia-driver-drift-check` compares the loaded module against the on-disk
userspace and exits non-zero when they disagree.

```bash
nvidia-driver-drift-check          # full banner + the processes a reboot would kill
nvidia-driver-drift-check --quiet  # one line, cheap enough for shell startup
```

| | |
|---|---|
| Reads | `/sys/module/nvidia/version` (fallback `/proc/driver/nvidia/version`) vs `/usr/lib/*-linux-gnu/libnvidia-ml.so.<ver>` |
| Exit 0 | in sync, **or no NVIDIA driver loaded** (so it is safe to run unconditionally on any machine) |
| Exit 1 | drift — new CUDA processes will fail |
| Silence one drift | `echo "580.159.03->580.173.02" > ~/.cache/nvidia-drift-ack` — returns automatically once either version changes |

**Why `--quiet` skips the process list**: `fuser /dev/nvidia0` walks all of
`/proc` (~240 ms here). The drift can't clear until a reboot, so a 17-line
banner on every new terminal trains you to ignore it. One line, no `fuser`.

Wire it into shell startup via `~/.config/zsh/tools/60_nvidia_drift.zsh`.
**Not** `/etc/update-motd.d/` — the script writes to stderr and `run-parts`
only collects stdout into `/run/motd.dynamic`, so the banner would never
appear while still costing 240 ms per login.

## Prevention: keep unattended-upgrades off the driver

`/etc/apt/apt.conf.d/52unattended-upgrades-local` blacklists the driver stack.
A higher-numbered drop-in rather than editing `50unattended-upgrades`, which
is a conffile and would prompt on every upgrade.

Four syntax facts, all of which are easy to get wrong:

| Rule | Why |
|---|---|
| apt.conf lists **append**, never override | `50unattended-upgrades` ships an empty `Package-Blacklist`, so the drop-in *is* the effective list. `#clear` is the only way to delete entries. |
| **No leading `^`** | u-u rewrites each entry into an APT pin as `'/^' + regex + '/'` → `/^^nvidia-/` |
| **No trailing `$`** | multiarch names carry `:i386` (e.g. `libnvidia-compute-580:i386`) that `$` won't match |
| Patterns are Python `re.match` | start-anchored, **not** end-anchored |

Verify the effective list, and simulate the match against real package names:

```bash
apt-config dump Unattended-Upgrade::Package-Blacklist   # no output = syntax error
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -iE 'blacklist|nvidia'
```

> `--dry-run` is safe with a live training job — every commit point is behind
> `if not dry_run:`; it only sets `Debug::pkgDPkgPM=1`.

**Deliberately not blacklisted**: `nvidia-settings`, `nvidia-prime` and
`libnvidia-egl-wayland1` are Ubuntu-main packages whose versions are
independent of the driver branch — they should keep getting security updates.
Blanket `^nvidia-`/`^libnvidia-` patterns freeze them too.

**This only blocks the unattended path.** PackageKit / gnome-software do not
read `Unattended-Upgrade::Package-Blacklist`; if the desktop updater offers
nvidia packages, cancel it and use the ritual below. `apt-mark hold` would
cover both, at the cost of blocking your own deliberate upgrades and printing
"kept back" on every apt run.

> If you do use `apt-mark hold`, build the list with `${binary:Package}`, not
> `${Package}` — the latter drops the arch qualifier and silently leaves every
> `:i386` package unheld, which is exactly half of the driver.

## Safe upgrade ritual

With the blacklist in place, driver updates accumulate silently. Once a month:

```bash
sudo apt update && apt list --upgradable 2>/dev/null | grep -i nvidia
fuser -v /dev/nvidia*                  # drain: no user processes
sudo apt full-upgrade
dkms status | grep nvidia              # must cover the kernel you will boot
sudo reboot                            # <- the step that is always skipped
nvidia-driver-drift-check && nvidia-smi
```

Step 5 is the whole point. An upgrade that lands at 06:02 and a reboot that
happens two weeks later is exactly the bug this page exists for.

> Don't write step 3 as `apt install --only-upgrade '~nnvidia'` — `~n` is an
> unanchored substring match and pulls in every package whose *name* contains
> "nvidia", making the transaction much larger than it looks.

## Long-running GPU jobs

A multi-day training run started from a terminal emulator lives in **that
terminal's cgroup** (`/user.slice/.../app-gnome-alacritty-<pid>.scope`).
Closing the window or logging out kills it — `nohup` only covers SIGHUP.

```bash
tmux new -s train 'bash run.sh'
# or
systemd-run --user --scope --unit=train bash run.sh
loginctl enable-linger $USER
```

Check what a reboot would actually cost before typing it:

```bash
fuser -v /dev/nvidia*                                    # everything holding the GPU
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
```

## Display topology of this box (David-Ubuntu)

| | |
|---|---|
| dGPU | `01:00.0` NVIDIA GA102 [RTX 3090] `10de:2204` — **drives the only connected output** (`card1-HDMI-A-1`) |
| iGPU | `0c:00.0` AMD Raphael `1002:13c0` — enabled in BIOS, **no display attached**, all outputs `disconnected` |
| `prime-select` | `on-demand` |
| Session | X11 |

**There is no iGPU fallback.** If the NVIDIA stack fails to bring up X, the
machine has no display at all. This is why an in-place driver upgrade is
dangerous here: between the upgrade and the reboot, Xorg holds ~94 deleted
mappings (`libglxserver_nvidia.so.<old>`, `libEGL_nvidia.so.<old>`, …) and
**any** X restart — logout, user switch, `systemctl restart gdm3`, suspend —
comes back on the new libs against the old module and lands on a black screen.

### amdgpu is currently blacklisted — and that was probably a mistake

`/etc/modprobe.d/blacklist-amdgpu.conf` exists on this box. It was added on
2026-07-25 after a `-22` probe failure that turned out to be **an artefact of
being booted in recovery mode**, not a driver bug:

```
amdgpu 0000:0c:00.0: probe with driver amdgpu failed with error -22
$ cat /proc/cmdline
… ro recovery nomodeset dis_ucode_ldr        # <- nomodeset is why
```

On a **normal** command line, same kernel, amdgpu initialises completely — all
ten IP blocks, VBIOS fetched, 2048M of VRAM ready. See
[`pitfalls/recovery-mode-resume-keeps-nomodeset-in-cmdline.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/recovery-mode-resume-keeps-nomodeset-in-cmdline.md).
The ATPX / vga_switcheroo lines that look alarming appear on healthy boots too.

**Remove the blacklist** unless the 57-minute boot below actually recurs:

```bash
sudo rm /etc/modprobe.d/blacklist-amdgpu.conf
sudo update-initramfs -u -k all
```

### The 57-minute boot is still unexplained

Separately, one boot on a normal command line ran 17:17:53 → 18:14:38 without
reaching a usable desktop. What is established:

- amdgpu initialised cleanly at 17:17:55 — not the cause.
- `dbus-daemon … Failed to activate service 'org.freedesktop.Notifications':
  timed out (service_start_timeout=120000ms)`, repeating every ~2m10s from 17:54.
- The `amdgpu … [drm] *ERROR* Not enough memory for command submission!` burst
  is timestamped 18:14:38 — the **last** second of that boot, i.e. during the
  forced reboot, not during startup.
- GDM started `gdm-wayland-session`, whereas the previous 12-day session was
  X11. `nvidia_drm modeset=1` is set and `/etc/gdm3/custom.conf` has no
  `WaylandEnable=false`, so nothing stopped GDM picking Wayland after the
  kernel + driver jump.

The X11 → Wayland flip is the strongest correlate but is **not proven**. If the
long boot recurs, change the session type first — not the GPU driver:

```bash
# /etc/gdm3/custom.conf
[daemon]
WaylandEnable=false
```

…or just pick "Ubuntu on Xorg" (gear icon) at the greeter.

### Would moving the display to the iGPU help?

It would free the desktop's VRAM off the 3090, but that is **~464 MiB of
24576 (1.9%)** — Xorg 112, gnome-remote-desktop 260, gnome-shell 24, the rest
single digits. Not the difference between OOM and not.

The real argument is **isolation**: a training OOM stops taking the desktop
with it, compositing stops stealing SM time, and — the one that matters here —
**X can be restarted without touching the GPU**, which removes the black-screen
trap above entirely.

Prerequisites: remove the amdgpu blacklist, boot on a normal command line, then
attach a cable to the motherboard output and set the BIOS primary display.

## Related

- [scheduled-jobs.md](scheduled-jobs.md) — `apt-daily-upgrade.timer`, which is
  what runs unattended-upgrades
- [hardware.md](hardware.md) — chassis/board sensors, one layer below
- `~/.dotfiles/bin/nvidia-driver-drift-check`
- `/etc/apt/apt.conf.d/52unattended-upgrades-local`
- `/etc/modprobe.d/blacklist-amdgpu.conf`
