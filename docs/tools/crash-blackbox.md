# crash-blackbox

A flight recorder for machines that **hard-power-off with no logs**.

When a box loses power outright — PSU trip, VRM fault, an AGESA reset — the kernel
never runs again, so journald's write buffer dies with it and the last chunk of
evidence is simply gone. That is why these failures present as "nothing in the
logs": the absence is a *consequence* of the failure mode, not evidence against it.

`crash-blackbox` samples the sensors every second and **`fsync`s every row**, so the
CSV survives the cut. Afterwards, `report` shows you the seconds leading up to it.

Full diagnostic ladder this belongs to:
[Random hard power-offs](../playbooks/random-hard-poweroff.md).

## Usage

```bash
crash-blackbox install              # system service, starts at boot (sudo)
crash-blackbox install --user       # user service, no sudo (see caveat below)
crash-blackbox status               # scope, service state, sample count, disk use
crash-blackbox report               # what the sensors said before each power cut
crash-blackbox report --seconds 60  # widen the window
crash-blackbox uninstall            # remove from whichever scope it's in (log kept)

crash-blackbox run                  # the sampling loop itself; the service runs this
```

The service is **opt-in** — installing the dotfiles does not start a recorder on
your machine. Run `crash-blackbox install` on the box you are actually debugging.
`status` and `uninstall` auto-detect the scope, so you never have to remember which
one you used.

## System scope vs `--user`

**System scope is the default and the right choice**, because it starts at boot
unconditionally. That is the whole point: the machine you are debugging dies at
times you do not choose.

Note that "system scope" does **not** mean the recorder runs as root. The unit pins
`User=` to the installing user (sampling only reads `/sys` and `/proc`); root is used
only to write the unit file into `/etc/systemd/system`.

`--user` needs **no sudo at all**, but a systemd user service does not start until
you log in — so **boot-to-login goes unrecorded**, and a cut in that window is
invisible. `loginctl enable-linger $USER` closes the gap by starting user services
at boot, but that itself needs sudo once. `install --user` warns when linger is off,
and `status` keeps reminding you.

Prefer `--user` only where you genuinely lack sudo. Even with linger enabled it is
the more fragile option: if linger is ever turned off, the recorder **silently**
stops covering boot, which is exactly the failure mode a black box must not have.

## Retention

The log lives at `~/.local/state/crash-blackbox/blackbox.csv`. At 1 Hz and ~350
bytes per row it grows about **29 MB/day**. It rotates at 64 MB (roughly two days)
keeping one previous file, so **disk use is hard-capped at 128 MB** — it cannot
grow without bound. `crash-blackbox status` prints the current size against that cap.

`report` reads the rotated `.1` file as well as the current one. That is deliberate:
a cut landing shortly after a rotation would otherwise show a run-up only as long as
the newly-created file, truncating exactly the seconds the tool exists to capture.

The service runs as the installing **user**, not root — `install` pins `User=` and
`XDG_STATE_HOME` into the unit. A system service defaults to root, and the state
path would then resolve against `/root`: the recorder would sit there reporting
`active` while writing somewhere you never look.

## What it records

Every second: CPU %, load, memory, every temperature / fan / voltage exposed by
`k10temp` / `coretemp` / `nvme` / `nct67xx` / `amdgpu`, NVIDIA GPU temp / power draw
/ utilisation / clock, and the top CPU consumer at that instant.

Each start writes a `=== BOOT ===` marker. `report` splits on those markers: any
segment that is followed by another boot marker is, by definition, a boot that ended
while the recorder was still running — i.e. the machine went down underneath it.

## Reading the report

```
Power cut #1 — last 30s before the machine died
          time    cpu_pct      load1   nct6799.fan7   k10temp.Tctl   gpu_power_w
  02:06:43           2.3       0.61         2596.0          66.25         26.49
  ...
```

Three things to look for, in order:

1. **A fan or pump dropping to 0 RPM** — a dead AIO pump kills a CPU faster than
   anything can be logged. Flagged explicitly.
2. **A thermal spike** (≥ 90 °C) or a **GPU power spike** (≥ 300 W) — a transient
   can trip a PSU's over-current protection in microseconds even when the unit's
   total wattage rating is nowhere near saturated. Both flagged.
3. **Nothing at all.**

Case 3 is the one people misread. Clean sensors right up to the cut is **not** an
inconclusive result — it says that nothing the machine could observe about itself
was wrong when it died, which points at the power path or the platform firmware
rather than at load or cooling. The report says so explicitly rather than printing
an empty section.

`report` also prints the drive's lifetime `unsafe_shutdowns` count (via `nvme
smart-log`) as an independent cross-check — the SSD firmware counts every power
loss regardless of what the OS managed to record.

## Dependencies

Nothing you have to install by hand — but one of them is easy to lose silently:

| Needs | Comes from | Missing ⇒ |
|---|---|---|
| `python3`, `ps`, `systemctl` | base system | n/a |
| `nvme` | `homelab_tools` (gated on an NVMe being present) | loses only the `unsafe_shutdowns` cross-check; degrades cleanly |
| `nvidia-smi` | the NVIDIA driver, **not** `homelab_tools` | loses the GPU columns; degrades cleanly |
| **Super-I/O kernel module** (`nct6775` / `it87`) | `homelab_tools` persists it into `/etc/modules-load.d/` | **loses every fan channel — including pump RPM** |

That last row is the trap. We read `/sys/class/hwmon` directly, so the `sensors`
binary is not needed — but the Super-I/O **kernel module** is, and no distro loads
it on its own. Without it, hwmon still shows CPU and NVMe temperatures, so nothing
looks broken; you have simply lost the pump tachometer, which is the *first* thing
`report` checks. `install` and `status` therefore both report the channel count and
warn loudly when zero fans are visible:

```
sensors : 20 temp, 7 fan channel(s)
```

If it says `0 fan channel(s)`, run `sudo sensors-detect` once (answer YES to the
safe probes) and restart the service. `liquidctl` is **not** a dependency — it is
installed alongside for manual AIO inspection, but `crash-blackbox` never calls it.

## Limits

- Linux + systemd only (`install` / `status` shell out to `systemctl`).
- **PSU telemetry does not exist** on most units. This records what the *board* can
  see, which is everything except the one number you most want.
- Super-I/O voltage rails (`nct6799.in0`…`in17`) are recorded but **unlabelled** —
  without a board-specific `sensors3.conf` you cannot tell which is +12 V. Do not
  build an argument on them.
- USB AIO pumps (ASUS Ryujin, NZXT Kraken) may be invisible to `liquidctl`. Fall
  back to the Super-I/O tachometers: the pump is the channel that holds a **steady**
  RPM regardless of temperature, while radiator/case fans track it.

## See also

- [Random hard power-offs](../playbooks/random-hard-poweroff.md) — the full ladder
- [Hardware CLIs](../sysadmin/hardware.md) — `lm-sensors`, `smartctl`, `nvme-cli`, `liquidctl`
- [`ping-monitor`](ping-monitor.md) — the same record-and-flag shape, for network latency
