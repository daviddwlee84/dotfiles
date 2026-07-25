# `nvidia-smi` dies with "Driver/library version mismatch" hours after an upgrade nobody ran

**Symptoms** (grep this section): `Failed to initialize NVML: Driver/library version mismatch`; `NVML library version: 580.173`; `cuInit` returns **804** / `CUDA_ERROR_COMPAT_NOT_SUPPORTED_ON_DEVICE`; `forward compatibility was attempted on non supported HW`; `torch.cuda.is_available()` suddenly `False`; a long-running training job keeps working fine while every NEW CUDA process fails; `modprobe -r nvidia` → `Module nvidia is in use`; `nvtop` silently shows only the iGPU; `/proc/driver/nvidia/version` disagrees with `dpkg -l | grep nvidia-utils`
**First seen**: 2026-07
**Affects**: Ubuntu 24.04 noble + NVIDIA proprietary driver (any branch) + `unattended-upgrades`; any box with long uptime between reboots
**Status**: prevented (`/etc/apt/apt.conf.d/52unattended-upgrades-local` blacklist + `nvidia-driver-drift-check`); the underlying behaviour is by-design and will never be "fixed"

## Symptom

```
$ nvidia-smi
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 580.173
```

Nothing was installed by hand. `dmesg` is clean — **zero Xid errors**. The GPU
is fine and busy. The confusing part:

- A PyTorch job that has been training for 27 hours keeps running at 99% GPU
  util, completely unaffected.
- Every new CUDA process fails immediately.
- `/var/run/reboot-required` was set hours ago and nothing surfaced it.

```
$ cat /proc/driver/nvidia/version
NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.159.03      <- loaded at boot
$ dpkg -l | grep nvidia-utils
ii  nvidia-utils-580   580.173.02-0ubuntu0.24.04.1               <- on disk now
```

## Root cause

`unattended-upgrades` replaced the NVIDIA **userspace** while the machine was
running. The **kernel module** cannot be swapped while the GPU is in use, so
the two halves drift apart:

```
$ grep -B2 -A3 nvidia /var/log/apt/history.log
Start-Date: 2026-07-25  06:02:51
Commandline: /usr/bin/unattended-upgrade
Upgrade: libnvidia-compute-580:amd64 (580.159.03-…, 580.173.02-…), nvidia-dkms-580 …
```

The origin that matched was `${distro_id}:${distro_codename}-security` —
the driver lives in `noble-security/restricted`, and Ubuntu's stock
`50unattended-upgrades` ships an **empty** `Package-Blacklist`, so nothing
stopped it. The u-u log says so verbatim: `Initial blacklist: `.

The running job survives because dpkg's replace is `unlink` + create-new.
`unlink` drops the *name*, not the inode — the process keeps its mapping:

```
$ ls -l /proc/<pid>/map_files/ | grep -E 'libcuda|libnvidia-ml'
-> '/usr/lib/x86_64-linux-gnu/libcuda.so.580.159.03 (deleted)'
-> '/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.159.03 (deleted)'
```

**The only fix is a reboot.** `rmmod` needs refcount 0, and on a box whose
display runs on that same GPU, Xorg + gnome-shell + mutter + every accelerated
app hold `/dev/nvidia*` open (refcount was 474 here).

### The trap inside the trap: don't restart X

Between the upgrade and the reboot, Xorg holds ~94 deleted mappings
(`libglxserver_nvidia.so.<old>`, `libEGL_nvidia.so.<old>`, …). **Any** X
restart — logout, user switch, `systemctl restart gdm3`, suspend — comes back
on the new libs against the old module. On a machine with no iGPU fallback
that is an unrecoverable black screen. Check before touching anything:

```bash
ls -l /proc/$(pgrep -x Xorg)/map_files/ | grep -c '(deleted)'
for c in /sys/class/drm/card*-*/status; do printf '%-28s %s\n' "$c" "$(cat $c)"; done
```

## Workaround

**Reboot.** Before you do, know what it costs — `fuser -v /dev/nvidia*` lists
every process that dies with it.

To monitor the GPU *without* rebooting (e.g. while a multi-day job finishes),
extract the OLD userspace and point `LD_LIBRARY_PATH` at it. Nothing is
installed system-wide and the running job is untouched:

```bash
mkdir -p /tmp/nvshim && cd /tmp/nvshim
apt-get download nvidia-utils-580=<OLD> libnvidia-compute-580=<OLD> libnvidia-cfg1-580=<OLD>
for f in *.deb; do dpkg-deb -x "$f" root/; done   # -x only: no maintainer scripts, no dpkg state
LD_LIBRARY_PATH=$PWD/root/usr/lib/x86_64-linux-gnu root/usr/bin/nvidia-smi
```

Restores `nvidia-smi` and lets new CUDA processes start. Does **not** restore
OpenGL/EGL/Vulkan (no `libGLX_nvidia`/`libEGL_nvidia` in those debs).

> Old versions vanish from the archive pool fast — `apt-get download <pkg>=<old>`
> starts 404-ing within days. Use `snapshot.ubuntu.com` then.
>
> **Tear the shim down the moment `/proc/driver/nvidia/version` changes**, not
> "after the reboot". Once the module is new, the shim produces the same error
> in the opposite direction and it looks identical.

Zero-install alternative that also works: `nvidia-settings` talks to X's
NV-CONTROL extension, not NVML, so it is unaffected.

```bash
DISPLAY=:1 nvidia-settings -t -q '[gpu:0]/GPUUtilization' -q '[gpu:0]/UsedDedicatedGPUMemory'
```

## Prevention

Two layers, both in place on this box:

1. `/etc/apt/apt.conf.d/52unattended-upgrades-local` — blacklists the driver
   stack so the background timer never touches it. Four easy-to-get-wrong
   syntax rules (lists append; no leading `^`; no trailing `$` because of
   `:i386`; `re.match` is start-anchored only) are documented in the doc page.
2. `nvidia-driver-drift-check` (`~/.dotfiles/bin/`) — compares
   `/sys/module/nvidia/version` against the on-disk `libnvidia-ml.so.<ver>`
   and exits 1 on drift. Wire into shell startup with `--quiet`.

Then upgrade deliberately: drain the GPU → `apt full-upgrade` → **reboot
immediately**. The 2026-07-25 incident was an upgrade at 06:02 and a reboot
twelve days late.

## Related

- [`docs/sysadmin/gpu-driver.md`](../docs/sysadmin/gpu-driver.md) — full story,
  the append-vs-override apt.conf semantics, the safe-upgrade ritual
- [`pitfalls/amdgpu-atpx-probe-fail-boot-hang-kernel-7.md`](amdgpu-atpx-probe-fail-boot-hang-kernel-7.md)
  — the *other* GPU trap hit during the same reboot
- `docs/sysadmin/scheduled-jobs.md` — `apt-daily-upgrade.timer`, the trigger
