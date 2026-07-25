# Boot takes 57 minutes to reach the desktop, or the iGPU vanishes entirely, on kernel 7.0

**Symptoms** (grep this section): `amdgpu 0000:0c:00.0: probe with driver amdgpu failed with error -22`; `amdgpu: ATPX version 1, functions 0x00000000`; `amdgpu: vga_switcheroo: detected switching method \_SB_.PCI0.GP17.VGA_.ATPX handle`; `amdgpu … [drm] *ERROR* Not enough memory for command submission!`; `dbus-daemon … Failed to activate service 'org.freedesktop.Notifications': timed out (service_start_timeout=120000ms)` repeating every ~2m10s; boot hangs for tens of minutes with no error on screen; `card2` missing from `/sys/class/drm/`; `journalctl --list-boots` shows a boot spanning ~1 hour
**First seen**: 2026-07
**Affects**: Ubuntu 24.04 noble HWE kernel **7.0.0-28-generic**, AMD Raphael iGPU `1002:13c0` (Ryzen 7000 desktop) alongside a discrete NVIDIA GPU. **6.17.0-35-generic probes the same hardware fine** — this is a 7.0 regression.
**Status**: worked around (`blacklist amdgpu`); no upstream fix identified

## Symptom

Two *different* outcomes from the same hardware and kernel, which is what
makes this confusing — the failure is nondeterministic.

**Outcome A — clean failure (harmless).** amdgpu gives up during probe. Boot
is fast and healthy, `systemctl --failed` is empty, but `card2` is gone from
`/sys/class/drm/`:

```
kernel: amdgpu: vga_switcheroo: detected switching method \_SB_.PCI0.GP17.VGA_.ATPX handle
kernel: amdgpu: ATPX version 1, functions 0x00000000
kernel: amdgpu: Virtual CRAT table created for CPU
kernel: amdgpu 0000:0c:00.0: probe with driver amdgpu failed with error -22
```

**Outcome B — half-initialised (the 57-minute boot).** amdgpu gets further,
then starves, and the desktop session wedges retrying dbus activation:

```
kernel: amdgpu 0000:0c:00.0: [drm] *ERROR* Not enough memory for command submission!    (x25)
dbus-daemon[2030]: [session uid=1000 pid=2030] Failed to activate service
                   'org.freedesktop.Notifications': timed out (service_start_timeout=120000ms)
```

That dbus line repeats every ~2m10s for **20+ minutes**. Nothing on screen
says why. `journalctl --list-boots` is how you see it after the fact:

```
IDX BOOT ID     FIRST ENTRY                 LAST ENTRY
 -2 67296dad…   Sat 2026-07-25 17:17:53 CST Sat 2026-07-25 18:14:38 CST   <- 57 minutes
 -1 fbdac588…   Sat 2026-07-25 18:15:28 CST Sat 2026-07-25 18:18:00 CST   <- recovery mode
  0 7e77d445…   Sat 2026-07-25 18:19:04 CST …                             <- fine
```

Easy to misattribute to whatever else changed in the same reboot (in our case
an NVIDIA driver upgrade — see the sibling pitfall). It is not related.

## Root cause

`ATPX` is the **laptop hybrid-graphics** ACPI switching interface. This desktop
board exposes an ATPX handle for a desktop part, and reports an **all-zero
function bitmask** (`functions 0x00000000`) — i.e. it advertises the interface
while supporting none of it. amdgpu's probe path takes the vga_switcheroo
branch and bails with `EINVAL` (`-22`).

Ruled out:

- **Not missing firmware.** `/lib/firmware/amdgpu/` has 116 matching blobs
  (they are `.zst`-compressed, so a naive `ls *.bin` returns nothing and
  misleads you).
- **Not the NVIDIA driver.** nvidia-drm initialises cleanly in the same boot,
  immediately after the amdgpu failure line.
- **Not the BIOS iGPU toggle.** The device enumerates fine in `lspci`
  (`0c:00.0 VGA compatible controller … [1002:13c0]`) with BARs assigned.

## Workaround

The iGPU has **no display attached** on this box (every `card2-*` output reads
`disconnected`), so it contributes nothing. Blacklisting removes the
nondeterminism at zero cost:

```bash
echo 'blacklist amdgpu' | sudo tee /etc/modprobe.d/blacklist-amdgpu.conf
sudo update-initramfs -u -k all
```

If you *need* the iGPU (e.g. to move the desktop off the dGPU), boot
**6.17.0-35-generic** instead — amdgpu works there. Keep it installed:

```bash
ls /boot/vmlinuz-*                  # confirm the older kernel survives autoremove
dkms status | grep nvidia           # and that DKMS still covers it
```

## Prevention

- Keep one known-good older kernel installed before jumping HWE series. GRUB's
  `Advanced options for Ubuntu` submenu is the escape hatch; `GRUB_DEFAULT=0`
  always selects the **newest** kernel, so a routine reboot silently moves you
  onto an untested one.
- Diagnose a slow boot with `journalctl --list-boots` (span per boot) plus
  `journalctl -b -N -p err` — not `systemd-analyze blame`, which only ever
  describes the boot you are currently in.
- On a box whose only display output is on the dGPU, treat a half-working iGPU
  as strictly worse than no iGPU.

## Related

- [`docs/sysadmin/gpu-driver.md`](../docs/sysadmin/gpu-driver.md) — display
  topology of this box, and why moving the monitor to the iGPU is blocked on
  this bug
- [`pitfalls/nvidia-nvml-driver-library-mismatch-after-unattended-upgrade.md`](nvidia-nvml-driver-library-mismatch-after-unattended-upgrade.md)
  — the unrelated NVIDIA trap that shared this reboot and made attribution hard
