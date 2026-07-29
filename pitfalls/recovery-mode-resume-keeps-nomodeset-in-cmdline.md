# The iGPU disappeared and amdgpu fails `-22` — you are still booted in recovery mode

**Symptoms** (grep this section): `amdgpu 0000:0c:00.0: probe with driver amdgpu failed with error -22`; `card2` missing from `/sys/class/drm/`; only the dGPU enumerates; `amdgpu` module loaded with refcount 0 and no bound devices; `amdgpu: ATPX version 1, functions 0x00000000`; `amdgpu: vga_switcheroo: detected switching method \_SB_.PCI0.GP17.VGA_.ATPX handle`; the NVIDIA proprietary driver works normally so nothing looks obviously wrong; `/proc/cmdline` contains `recovery nomodeset dis_ucode_ldr`
**First seen**: 2026-07
**Affects**: any Ubuntu box where someone entered the GRUB recovery menu and chose **resume**; independent of kernel version and GPU vendor
**Status**: not a bug — reboot normally

## Symptom

The AMD iGPU is gone. `lspci` still lists it, but it has no DRM node and
amdgpu refuses to bind:

```
$ journalctl -k -b | grep amdgpu
amdgpu: vga_switcheroo: detected switching method \_SB_.PCI0.GP17.VGA_.ATPX handle
amdgpu: ATPX version 1, functions 0x00000000
amdgpu: Virtual CRAT table created for CPU
amdgpu: Topology: Add CPU node
amdgpu 0000:0c:00.0: probe with driver amdgpu failed with error -22

$ ls /sys/class/drm/ | grep card
card1            # the NVIDIA dGPU only - card2 is gone
```

Everything else looks healthy: `systemctl --failed` is empty, `nvidia-smi`
gives a full readout, the desktop works. That is exactly what makes this
hard — the NVIDIA proprietary module does **not** honour `nomodeset`, so the
only visible casualty is the AMD side.

## Root cause

You are still in recovery mode. GRUB's recovery entry appends
`recovery nomodeset dis_ucode_ldr`, and choosing **resume** from the recovery
menu continues to a normal-looking desktop **while keeping that command line**:

```
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-7.0.0-28-generic root=UUID=… ro recovery nomodeset dis_ucode_ldr
```

- `nomodeset` — in-tree DRM drivers refuse to do kernel mode setting.
  amdgpu's probe bails with `EINVAL` (`-22`). **This is the only one of the
  three that reliably does anything.**
- `recovery` and `dis_ucode_ldr` — on kernel 7.0 the kernel does not even
  recognise them:
  ```
  kernel: Unknown kernel command line parameters "recovery dis_ucode_ldr",
          will be passed to user space
  ```
  `recovery` is consumed by Ubuntu's init scripts (and after "resume" it does
  not restrict the systemd target — `graphical.target` comes up normally).

Don't assume `dis_ucode_ldr` cost you microcode fixes without checking — on a
board whose BIOS already ships the revision the kernel would load, it is a
no-op. Compare the normal boot against the recovery boot:

```
boot -2 (normal):   microcode: Current revision: 0x0b404035
                    microcode: Updated early from: 0x0b404035   # same rev = no-op
boot  0 (recovery): /proc/cpuinfo -> microcode : 0xb404035      # identical
```

The ATPX / vga_switcheroo lines are a **red herring** — they appear on a
perfectly healthy boot too. Don't chase them.

### The trap: amdgpu is fine, and a `-22` here proves nothing

On the same machine, same kernel, with a **normal** command line, amdgpu
initialises completely:

```
amdgpu 0000:0c:00.0: initializing kernel modesetting (IP DISCOVERY 0x1002:0x13C0 …)
amdgpu 0000:0c:00.0: detected ip block number 0..9 <common/gmc/ih/psp/smu/dm/gfx/sdma/vcn/jpeg>
amdgpu 0000:0c:00.0: Fetched VBIOS from VFCT
amdgpu 0000:0c:00.0: [drm] ATOM BIOS: 102-RAPHAEL-008
amdgpu 0000:0c:00.0:  2048M of VRAM memory ready
amdgpu: Topology: Add GPU node
```

If you diagnose the `-22` as a driver or kernel regression you will "fix" it by
blacklisting a module that was never broken — and lose the iGPU permanently for
no reason. That is exactly what happened here on 2026-07-25.

Confirmed live on 2026-07-29 by removing the blacklist and loading the module
by hand on a normal command line, no reboot needed:

```
$ sudo modprobe amdgpu
[drm] Initialized amdgpu 3.64.0 for 0000:0c:00.0 on minor 0
amdgpu 0000:0c:00.0: ring comp_1.3.1 / kiq_0.2.1.0 / sdma0 / vcn_dec_0 /
                     vcn_enc_0.0 / jpeg_dec  … all initialised
amdgpu 0000:0c:00.0: [drm] Cannot find any crtc or sizes   # expected: no monitor
amdgpu 0000:0c:00.0: Runtime PM not available              # expected: desktop iGPU
```

Zero errors, `card0` appears, the PCI device binds. The module was fine the
whole time.

> **`modprobe` of a GPU driver restarts the X session.** The running Xorg picks
> the new DRM device up via udev, then gdm rebuilds the session ~10 s later —
> new Xorg and gnome-shell PIDs, every graphical app gone. It is a cheaper test
> than a reboot only in wall-clock terms, not in disruption. Close your work
> first, or just reboot.

## Workaround

```bash
cat /proc/cmdline            # look for: recovery nomodeset dis_ucode_ldr
sudo reboot                  # pick the NORMAL entry, not Advanced -> recovery
```

Confirm you are out:

```bash
cat /proc/cmdline                  # should be: ro quiet splash vt.handoff=7
ls /sys/class/drm/ | grep card     # card2 back (if amdgpu is not blacklisted)
```

Don't use `grep microcode /proc/cpuinfo` as the check — that line is present
either way. `journalctl -k -b | grep microcode:` is the honest one: the loader
only logs on a boot where it actually ran.

## Prevention

- **Always check `/proc/cmdline` first** when a device vanishes after a
  troubled boot, before reading a single driver log line. One command rules out
  an entire class of phantom hardware bugs.
- Recovery mode's **resume** is not "continue booting normally". It is
  "continue booting *with the recovery command line*". There is no on-screen
  indication afterwards.
- Compare boots rather than reading one in isolation — the command line is the
  first thing to diff:
  ```bash
  for b in -3 -2 -1 0; do
    printf 'boot %-3s %s\n' "$b" \
      "$(journalctl -k -b $b 2>/dev/null | grep -m1 -oP 'Kernel command line: \K.*')"
  done
  ```

## Unresolved sibling: the 57-minute boot

The boot that *sent* us into recovery in the first place is still unexplained.
On a **normal** command line, boot -2 ran 17:17:53 → 18:14:38 without reaching
a usable desktop. What is established:

- amdgpu initialised cleanly at 17:17:55 (log above) — **not** the cause.
- `dbus-daemon … Failed to activate service 'org.freedesktop.Notifications':
  timed out (service_start_timeout=120000ms)` repeated every ~2m10s from 17:54.
- The `amdgpu … [drm] *ERROR* Not enough memory for command submission!` burst
  is timestamped 18:14:38 — the **last** second of that boot, i.e. during the
  forced reboot, not during startup.
- GDM started `gdm-wayland-session` on both boot -2 and boot -1, whereas the
  previous 12-day session was X11 (`XDG_SESSION_TYPE=x11`). `nvidia_drm
  modeset=1` is set and `/etc/gdm3/custom.conf` has no `WaylandEnable=false`,
  so nothing was stopping GDM from picking Wayland after the kernel/driver
  jump.

The X11 → Wayland flip is the strongest correlate, but it is **correlation, not
proof**. If the long boot recurs, change the session type first
(`WaylandEnable=false` in `/etc/gdm3/custom.conf`, or pick "Ubuntu on Xorg" at
the greeter) — not the GPU driver.

## Related

- [`docs/sysadmin/gpu-driver.md`](../docs/sysadmin/gpu-driver.md) — display
  topology of this box
- [`pitfalls/nvidia-nvml-driver-library-mismatch-after-unattended-upgrade.md`](nvidia-nvml-driver-library-mismatch-after-unattended-upgrade.md)
  — the unrelated NVIDIA trap that shared the same afternoon and made
  attribution genuinely hard
