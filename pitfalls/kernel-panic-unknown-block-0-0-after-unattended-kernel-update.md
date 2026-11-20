# Boot dies with `Kernel panic … unknown-block(0,0)` after an unattended kernel update

**Symptoms** (grep this section): boot stops at `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)`; the newest kernel in GRUB panics while an older one under *Advanced options for Ubuntu* boots fine; `ls /boot` shows `vmlinuz-<new>` with **no** matching `initrd.img-<new>` while `/boot/initrd.img` already points at it; `dpkg -l` shows `iF` (half-configured) on `linux-image-<new>-generic` / `linux-headers-<new>-generic` and `iU` on `linux-headers-generic-hwe-24.04`; every daily `/var/log/apt/history.log` entry from `/usr/bin/unattended-upgrade` ends with `Error: Sub-process /usr/bin/dpkg returned an error code (1)`; `/var/log/unattended-upgrades/unattended-upgrades-dpkg.log` has `run-parts: /etc/kernel/header_postinst.d/dkms exited with return code 11` and `dkms autoinstall on <new>/x86_64 failed for ovpn-dco(10)`; Grafana "workstation silent for 2h" firing for a day after an ordinary shutdown
**First seen**: 2026-11
**Affects**: Ubuntu 24.04 HWE (seen moving 7.0.0-30 → 7.0.0-42) with any out-of-tree DKMS module that stops compiling against the new kernel — here `openvpn-dco-dkms 0.2.20260526`; NVIDIA DKMS built fine
**Status**: fixed on David-Ubuntu (removed `openvpn-dco-dkms`; kernel 7.0 ships the in-tree `ovpn` module); prevention below

## Symptom

The machine was shut down normally (power key, `systemd-logind: The system will
power off now!`), and the next boot never came up. GRUB's default entry booted
the new kernel and stopped at the panic screen; the box sat there until someone
was physically present. Choosing `7.0.0-30-generic` under *Advanced options*
booted normally.

On the surviving kernel:

```
$ ls /boot | grep -E 'initrd|vmlinuz'
initrd.img -> initrd.img-7.0.0-42-generic        # dangling target
initrd.img-7.0.0-30-generic
vmlinuz -> vmlinuz-7.0.0-42-generic
vmlinuz-7.0.0-42-generic                          # no initrd.img-7.0.0-42-generic
$ dpkg -l | grep 7.0.0-42
iF linux-headers-7.0.0-42-generic
iF linux-image-7.0.0-42-generic
```

```
$ grep -A3 'Building module' /var/log/unattended-upgrades/unattended-upgrades-dpkg.log
make -j32 KERNELRELEASE=7.0.0-42-generic ... REVISION=0.2.20260526-1+26.1...(bad exit status: 2)
Error! Bad return status for module build on kernel: 7.0.0-42-generic (x86_64)
Consult /var/lib/dkms/ovpn-dco/0.2.20260526-1+26.1/build/make.log for more information.
dkms autoinstall on 7.0.0-42-generic/x86_64 succeeded for nvidia
dkms autoinstall on 7.0.0-42-generic/x86_64 failed for ovpn-dco(10)
run-parts: /etc/kernel/header_postinst.d/dkms exited with return code 11
dpkg: error processing package linux-headers-7.0.0-42-generic (--configure):
 installed linux-headers-7.0.0-42-generic package post-installation script subprocess returned error exit status 11
```

```
$ grep error /var/lib/dkms/ovpn-dco/*/build/make.log
drivers/net/ovpn-dco/udp.c:346:51: error: passing argument 2 of 'setup_udp_tunnel_sock' from incompatible pointer type [-Werror=incompatible-pointer-types]
drivers/net/ovpn-dco/tcp.c:486:31: error: assignment to 'int (*)(struct sock *, struct msghdr *, size_t,  int)' ... from incompatible pointer type
```

## Root cause

A chain, each link silent on its own:

1. `unattended-upgrades` unpacks the new `linux-image` + `linux-headers`.
2. The headers' postinst runs `dkms autoinstall`. One out-of-tree module
   (`ovpn-dco`) no longer compiles against the new kernel's networking API, so
   the hook exits non-zero and dpkg leaves the kernel packages **half-configured**.
3. `update-initramfs` runs from the image's postinst **trigger**, which never
   completes, so the new kernel gets no initramfs. But the `/boot/vmlinuz` and
   `/boot/initrd.img` symlinks and the GRUB menu entry for it already exist
   (`10_linux` happily lists a `vmlinuz` without its initrd).
4. Every following morning unattended-upgrades retries, fails the same way, and
   logs `dpkg returned an error code (1)` — nobody reads it.
5. Nothing happens until the next reboot: `GRUB_DEFAULT=0` picks the newest
   entry, the kernel has no initramfs to load the NVMe/ext4 drivers, and panics
   with `unknown-block(0,0)` — "no block device at all".

So the panic is **not** a kernel regression and **not** a disk fault; the outage
was lurking from the first failed unattended run (6 days here) and was only
triggered by an unrelated, clean power-off.

A second trap made the obvious fix fail: `/boot` was a 944 MB partition with
~123 MB free, and each initrd that embeds the NVIDIA DKMS module + GSP firmware
is **~254 MB** (`nvidia.ko` alone is 122 MB unstripped; `gsp_ga10x.bin` 75 MB).
Three kernels plus a stray orphan initrd left no room to generate a fourth.

## Workaround

From an older working kernel (GRUB → *Advanced options for Ubuntu*):

```sh
# 1. Remove (or fix) the module that breaks the DKMS hook. Kernel ≥ 6.16 ships
#    the in-tree `ovpn` module, so openvpn-dco-dkms is no longer needed.
sudo apt purge openvpn-dco-dkms
#    apt finishes the pending configure → initrd generated → update-grub runs.

# 2. Make room in /boot BEFORE the next kernel arrives (~270 MB per kernel).
#    Keep the running kernel + one known-good fallback; purge the rest by name
#    (not `apt autoremove`, which may also take unrelated packages).
sudo apt purge linux-image-<old>-generic linux-modules-<old>-generic \
  linux-modules-nvidia-580-<old>-generic linux-objects-nvidia-580-<old>-generic \
  linux-signatures-nvidia-<old>-generic
df -h /boot

# 3. Verify before rebooting
ls -lh /boot/initrd.img-<new>-generic
dpkg -l | awk '/^i[^i]/'          # expect no output
dkms status | grep <new>
```

Side effect to expect: purging the kernel that `linux-modules-nvidia-580-generic-hwe-24.04`
pointed at makes apt upgrade that meta package, which drags the NVIDIA userspace
to a newer driver. Until the next reboot `nvidia-smi` reports
`Failed to initialize NVML: Driver/library version mismatch`.

## Prevention

- **GRUB remembers the last chosen entry** (David-Ubuntu, 2026-11):
  `/etc/default/grub.d/99-saved-default.cfg` with `GRUB_DEFAULT=saved` +
  `GRUB_SAVEDEFAULT=true`, then `sudo grub-set-default 0 && sudo update-grub`.
  After a rescue via *Advanced options*, later reboots stay on the good kernel
  instead of falling back into the panic. It does **not** stop a fresh kernel
  from panicking on its first boot — the top "Ubuntu" entry always tracks the
  newest kernel. To return to newest after a rescue: `sudo grub-set-default 0`.
  Deliberately **not** managed by ansible: it is host boot config, and pushing
  it via `fleet-apply` to cloud VMs/NAS with their own `grub.d` overrides risks
  an unbootable remote host.
- **Watch for the lurking state, not the panic**: alert on (a) `/boot` usage
  above ~80 % and (b) any `Error:` line in `/var/log/apt/history.log` /
  non-empty `dpkg --audit`. Either would have flagged this 6 days early.
- Treat every out-of-tree DKMS package as a kernel-update liability; prefer the
  in-tree module when the kernel gains one (`ovpn` since 6.16).
- `/boot` sizing: with NVIDIA-in-initramfs, budget ~270 MB per kernel; two
  kernels + headroom for a third is the minimum.

## Related

- [`docs/playbooks/random-hard-poweroff.md`](../docs/playbooks/random-hard-poweroff.md)
  Rung 1 — "was it even a crash?": this incident's power-off was a clean
  shutdown; the outage was the *next* boot.
- Sibling pitfall: [`recovery-mode-resume-keeps-nomodeset-in-cmdline`](recovery-mode-resume-keeps-nomodeset-in-cmdline.md)
  (another "rescued via the GRUB menu, now the boot is subtly different" trap).
