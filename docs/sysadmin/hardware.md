# Hardware monitoring (homelab)

Sysadmin question for a **physical** box: **is the hardware healthy — fans
spinning, temps sane, RAID optimal, disks not dying?**

This page documents the `hw-*` helpers and the `homelab_tools` ansible role
(chezmoi prompt `installHomelabTools`). For the dense reference table see
[helpers.md](helpers.md#hardware). This is a sibling of
[disk.md](disk.md) (filesystem-level) one layer down at the metal.

> Linux + physical only. The role is a no-op on macOS and inside VMs; the
> `hw-*` shell helpers are defined on Linux only.

## Three sensor planes (the gotcha)

The single most confusing thing about server sensors is that **there are
three independent sources** and they don't see each other:

| Plane | Reads | Helper | Notes |
|---|---|---|---|
| **BMC / IPMI** | chassis fans, inlet/board temps, PSU, System Event Log | `hw-fans` `hw-temps` `hw-sel` | The baseboard management controller. Root-only (`/dev/ipmi0`). |
| **lm-sensors** | on-board Super-I/O / PCI temp + fan chips | `hw-sensors` | Run `sudo sensors-detect` once to enable kernel modules. |
| **RAID card (storcli)** | controller ROC chip temp + enclosure sensors | `hw-raid` | The MegaRAID/LSI card has its *own* temp; the backplane may report **0 fans / 0 temp sensors**. |

**Key trap**: a passive **SGPIO backplane** reports `Fans = 0`, `TSs = 0` to
the RAID card — that is normal, not a fault. The chassis fans live on the
**BMC** plane (`hw-fans`), not the RAID plane. Don't conclude "no fans" from
`storcli /cALL/eALL show all` showing zero — look at `ipmitool sdr type fan`.

## Quick CLI

```bash
hw-status          # one-screen sweep: fans + temps + RAID + SMART + SEL errors
hw-fans            # chassis fan RPM (BMC)
hw-temps           # BMC temps + lm-sensors
hw-sensors         # full lm-sensors dump
hw-raid            # MegaRAID: controller status, VDs/PDs, ROC temp, enclosure
hw-smart           # per-disk SMART health verdict (all physical disks)
hw-smart /dev/sda  # full smartctl -a report for one device
hw-sel             # BMC System Event Log (last 20; --all for full)
```

Like the audit / disk helpers, these are shell **functions**, so
`sudo hw-fans` does NOT work (sudo spawns a fresh process without your
functions). Warm the sudo cache once with `sudo -v` and each helper
auto-elevates from there. Non-interactive callers get a clear hint instead.

## What gets installed, and when

The `homelab_tools` role installs each tool **only when the matching hardware
is detected**, so a box without a RAID card / NVMe drive / BMC doesn't pull in
unused packages:

| Tool | Package | Installed when |
|---|---|---|
| lm-sensors | `lm-sensors` | any physical Linux host |
| smartmontools | `smartmontools` | any physical Linux host |
| ipmitool | `ipmitool` | `/dev/ipmi*` exists **or** DMI type 38 (IPMI Device) present |
| nvme-cli | `nvme-cli` | an NVMe controller appears in `lspci` |
| storcli | (vendor download) | a RAID controller appears in `lspci` |
| liquidctl | `liquidctl` | a USB cooler / telemetry PSU appears in `lsusb` |

Detection runs read-only `lspci` / `dmidecode` / `lsusb` probes; results are
printed by the role's `debug` task so you can see what it decided.

**CentOS/RHEL 7 (`oldEL`)** takes a separate path: `ansible.builtin.yum` is
routed through the dnf backend in ansible-core >= 2.19, which aborts the whole
play on yum3/python2 hosts with `Could not detect which major revision of dnf
is in use` + `pkg_mgr: unknown`. On those hosts the role shells out to the
system `yum` instead, keeping it idempotent with an `rpm -q` pre-check (so a
no-op apply never invokes yum). The `pciutils`/`dmidecode` prerequisites are
also probed with `command -v` first — on EL7 they are normally present
already, in which case nothing is installed at all.

The role also persists the **Super-I/O kernel module** into
`/etc/modules-load.d/board-sensors.conf`, resolving which module actually backs the
fan channels (`nct6775` on Nuvoton boards, `it87` on ITE) rather than assuming.
Installing `lm-sensors` alone does **not** make the board's fan tachometers appear —
no distro loads that module on its own, and until it is loaded `/sys/class/hwmon`
shows CPU and NVMe temperatures but **zero fan channels**. Nothing looks broken; you
have just lost pump RPM, which is what [`crash-blackbox`](../tools/crash-blackbox.md)
checks first when a machine hard-powers-off.

The role does not run `sensors-detect` for you — it probes I2C/SMBus buses and is
not something to fire unattended. If no fan channels exist yet, the role says so and
points at the one-time manual step.

## liquidctl — USB coolers and PSU telemetry

`liquidctl` talks to AIO coolers and PSUs that expose a **USB** interface:

```bash
liquidctl list          # what it can actually see
sudo liquidctl status   # pump RPM, coolant temp, fan RPM, (some) PSU rails
```

Two caveats that cost real debugging time:

- **Coverage is per-model, not per-vendor.** Being an NZXT/ASUS/Corsair device is
  not enough — `liquidctl` may enumerate the board's Aura controller and still not
  support the cooler sitting next to it (ASUS Ryujin III is a current example). Run
  `liquidctl list` before you conclude the pump is dead.
- **Most PSUs have no telemetry at all.** Only a few Corsair/NZXT units report over
  USB (also exposed as the `corsair-psu` hwmon driver). Every be quiet! / Seasonic /
  most others report **nothing** — there is no software path to their rails, and no
  package will give you one.

When the pump is invisible to `liquidctl`, fall back to the Super-I/O tachometers in
`sensors`: the **pump is the channel holding a steady RPM regardless of temperature**,
while radiator/case fans track it. See
[Random hard power-offs](../playbooks/random-hard-poweroff.md).

## Installing storcli

`storcli` is **not in distro repos** — Broadcom ships it as a zip behind a
support portal. The role therefore treats it as a best-effort vendor download
gated on the `homelab_storcli_url` role variable:

- **Left empty (default)**: if a RAID controller is detected but `storcli` is
  missing, the role prints a hint and moves on (no failure). Install manually
  and drop the binary on `PATH` (`/usr/local/sbin/storcli` is conventional).
- **Set to a reachable tarball/zip URL** (x86_64 only): the role downloads,
  extracts, finds the `storcli`/`storcli64` binary and installs it to
  `~/.local/bin`. Override in your ansible vars or `~/.shellrc.adhoc` workflow.

If the download URL rots, capture it in a `pitfalls/` note rather than
hard-coding a fragile URL in the role.

## Daily / weekly recipes

### Morning hardware sweep

```bash
hw-status
```

One screen. Anything red or a non-`OK`/non-`Optimal` line → drill in with the
specific helper (`hw-raid`, `hw-smart /dev/sdX`, `hw-sel --all`).

### "Is a disk dying?"

```bash
hw-smart                 # verdict per disk; look for non-PASSED
hw-smart /dev/sdb        # full attributes: reallocated sectors, pending, CRC
```

Reallocated/pending sector counts climbing, or `SMART overall-health` =
`FAILED`, means replace the disk. (This page's sibling reason for existing:
we pulled a disk this way — see also [disk.md](disk.md) for the unmount /
fstab side.)

### "Is the RAID OK?"

```bash
hw-raid
```

Look for `Controller Status = Optimal` and no `Degraded`/`Failed` VDs. The
`ROC temperature` line is the RAID chip itself — warm is normal (LSI 3108
runs ~55–80 °C with airflow; ~95–100 °C is the warning ceiling). A sustained
high ROC temp points at weak airflow around the card, not a data problem.

### "Did the hardware log a fault?"

```bash
hw-sel               # recent BMC events
hw-sel --all         # full System Event Log
```

PSU loss, ECC errors, thermal trips and chassis-intrusion all land here.

## Caveats

- **`ns` / "No Reading" rows are unpopulated slots**, not faults — common for
  `FRNT_FAN2` / `REAR_FAN2` / spare PSU temp sensors on partially-populated
  chassis.
- **IPMI is root-only** (`/dev/ipmi0`) — every `hw-fans`/`hw-temps`/`hw-sel`
  call elevates.
- **`sensors` empty?** Run `sudo sensors-detect` once (answer YES to the safe
  probes), then reload modules or reboot.
- **storcli controller index**: helpers use `/cALL`; multi-controller hosts
  get all of them. For one card use `storcli /c0 ...` directly.
- **Install-only**: the role does **not** enable `smartd` / `ipmievd`
  services (repo is install-only by design). Continuous monitoring/alerting
  would be a separate opt-in timer.

## See also

- [Disk / filesystem monitoring](disk.md) — the filesystem layer above the metal
- [Service health](services-health.md) — `health-check` morning summary (OS side)
- [Helpers in this repo](helpers.md#hardware) — `hw-*` reference table
