# Diagnosing random hard power-offs

Symptom: the machine **cuts power outright** — no kernel panic, no BSOD-equivalent,
no shutdown sequence. It just stops, and comes back up as if someone yanked the
cord. Often blamed on "load" or "overheating" because it *feels* like the box gave
up under stress, but that is usually wrong.

This page is the diagnostic ladder that separates the three things people conflate:
**software crash**, **thermal/load limit**, and **loss of power**. They look
identical from the desk chair and have nothing in common underneath. The tool
referenced is [`crash-blackbox`](../tools/crash-blackbox.md).

## The mental model

Work out **how the machine died** before you theorise about *why*. There are only
three exits, and they leave completely different fingerprints:

| Exit | Fingerprint | Where to look |
|---|---|---|
| **Kernel panic / oops** | Kernel ran long enough to record something | `/sys/fs/pstore`, `journalctl -k -b -1`, `kdump` |
| **Thermal or OOM limit** | Something in the log *decided* to act | `oom-kill` lines, `thermal`/`throttl` messages, temps at the limit |
| **Loss of power** | Log ends **mid-sentence**, no shutdown sequence at all | Nothing — and that absence *is* the signal |

The third one is the trap. Because journald buffers writes, a power cut takes the
last chunk of log with it, so the evidence you most want is exactly the evidence
that does not exist. **Do not read "no error in the log" as "no hardware problem."**
On a power cut it is the expected reading.

## Rung 1 — was it even a crash?

```bash
journalctl --list-boots       # every boot the journal has seen
last -x reboot shutdown       # wtmp's view
```

For each suspicious boot, look at how it *ended*:

```bash
journalctl -b -1 -n 25 -o short-precise
```

- Ends with `systemd-shutdown`, `Reached target reboot.target`, `Journal stopped`
  → **clean reboot.** Not a crash. Someone or something asked for it. Rule it out
  and stop chasing it.
- Ends **mid-log-line**, with an unrelated daemon chattering → **hard cut.**
  Continue down the ladder.

This rung matters more than it looks: a run of "crashes" routinely contains one or
two ordinary reboots, and including them wrecks any pattern you try to infer.

## Rung 2 — get an independent count

The drive keeps its own tally, and unlike the journal it survives everything:

```bash
sudo nvme smart-log /dev/nvme0n1 | grep -iE "unsafe_shutdowns|media_errors|critical_warning"
```

`unsafe_shutdowns` is incremented by the SSD's own firmware every time it lost
power without being told to flush. It is the ground truth for "how many times has
this actually happened", and it is usually much higher than the user thinks —
which reframes the problem from "it started tonight" to "this has been degrading
for months."

## Rung 3 — kill the "load was too high" theory

This is the rung that saves the most wasted effort, and `sysstat` (if installed)
already has the data — retroactively, for crashes that already happened:

```bash
sar -f /var/log/sysstat/sa$(date +%d) -s 00:30:00 -e 01:20:00   # CPU
sar -q -f /var/log/sysstat/sa$(date +%d) -s 00:30:00 -e 01:20:00 # load average
sar -r -f /var/log/sysstat/sa$(date +%d) -s 00:30:00 -e 01:20:00 # memory
```

**If any crash happened while the machine was idle, load is dead as a theory.**
A box sitting at 96% idle with three quarters of its RAM free does not die of
overwork. One idle crash outweighs any number of busy ones — it only takes one
counterexample to kill the hypothesis, and it collapses "load", "thermal", and
"OOM" simultaneously.

## Rung 4 — record the seconds you are missing

Everything above is archaeology on logs that, by construction, stop just before
the interesting part. To get the actual run-up you need a recorder that fsyncs
every sample, so the cut cannot eat the tail:

```bash
crash-blackbox install     # systemd service, samples every second, fsyncs each row
# ... wait for the next cut ...
crash-blackbox report      # the last 30s before each power loss
```

Read the report for three things, in order:

1. **A fan or pump dropping to 0 RPM.** A failed AIO pump kills a CPU fast enough
   that nothing gets logged. `crash-blackbox report` flags this explicitly.
2. **A thermal spike** to 90 °C+, or a **GPU power spike**. A transient spike on a
   high-TDP card can trip the PSU's over-current protection in microseconds —
   the total wattage rating can be ample and it still trips.
3. **Nothing at all.** Sensors clean, temps flat, fans steady, right up to the cut.

Case 3 is not a failed investigation — **it is the finding.** It means nothing the
machine could observe about itself was wrong when it died, which points at the
power path or the platform firmware, not at load or cooling.

## Rung 5 — the power path and the firmware

At this point you are choosing between a small number of causes. Order them by how
cheap they are to rule out, not by how likely they feel:

- **BIOS / AGESA older than the CPU.** Check this *first* — it is free, and it is
  routinely the answer on AM5. A board can happily POST a CPU it never officially
  supported (generic microcode is enough to boot), while missing every stability
  fix written for it. Random resets with no logs, at idle *and* under load, is the
  classic presentation.

  ```bash
  sudo dmidecode -s bios-version && sudo dmidecode -s bios-release-date
  grep -m1 microcode /proc/cpuinfo
  ```

  Compare the BIOS date against the **CPU's launch date**. A BIOS that predates the
  CPU is a red flag on its own. Then check the vendor's release notes for the
  version that *first lists your exact SKU* — "supports Ryzen 9000" and "supports
  Ryzen 9000X3D" are different lines in the changelog, often hundreds of versions
  apart.

- **Multi-rail OCP.** Some high-end PSUs ship a multi-rail/single-rail switch. In
  multi-rail mode a single 12 V rail can trip on a big GPU's transient spike even
  though the unit's total rating is nowhere near saturated. Flip it to single-rail.

- **Cabling.** Daisy-chained PCIe power (one cable feeding two connectors on a
  300 W+ card) is a common cause. Use independent cables. Reseat both ends.

- **Memory, even without an overclock.** A defective DIMM misbehaves at JEDEC
  speeds too. `memtest86+` (a GRUB entry once installed) for at least one full pass.
  Note that finding EXPO/XMP *disabled* does not exonerate the RAM — it only
  exonerates the overclock.

- **The PSU itself.** Wattage is not health. A 1200 W unit with aging capacitors
  browns out at idle just as happily as under load. This is the diagnosis of
  exclusion — it is also the expensive one, so genuinely exhaust the list above
  before buying.

## What you cannot read from software

There is no PSU telemetry on most units. A handful of Corsair/NZXT models expose it
over USB (`corsair-psu` hwmon, `liquidctl`); most — including every be quiet! unit —
expose nothing at all. The motherboard's Super-I/O chip (`nct6799` and friends)
reports ~18 voltages, but without a board-specific `sensors3.conf` mapping the rails
are unlabelled (`in0`…`in17`) and you cannot tell which one is +12 V. Do not build
an argument on them.

Likewise, AIO coolers on USB (ASUS Ryujin, NZXT Kraken) need `liquidctl` and are not
always supported. When the pump is invisible there, fall back to the Super-I/O fan
tachometers: the **pump is the one that holds a steady RPM regardless of temperature**,
while case/radiator fans track it. `crash-blackbox` records all of them, so a pump
that dies mid-flight is visible after the fact even when you cannot name it live.

## See also

- [`crash-blackbox`](../tools/crash-blackbox.md) — the recorder and its `report` output
- [Hardware CLIs](../sysadmin/hardware.md) — `lm-sensors`, `smartctl`, `nvme-cli`, `liquidctl`
