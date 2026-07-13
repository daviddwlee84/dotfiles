# Wake-on-LAN wakes the box from suspend (S3) but not from full shutdown (S5)

**Symptoms** (grep this section):
- `wake <host>` / `wakeonlan <MAC>` powers the machine on after `sudo systemctl suspend`, but does **nothing** after `sudo poweroff` — the box stays dark and needs a physical power-button press.
- `sudo ethtool eno1 | grep -i wake-on` shows `Wake-on: g` — the OS side is armed correctly, so it *looks* right.
- No error anywhere: the sender reports `wake: sent 3x magic packet to …` and exits 0; the target simply never reacts from S5.
- Seen on ASUS boards + Intel I225/I226 (`igc` driver), but the mechanism is vendor-agnostic.

**First seen**: 2026-06 on `David-Ubuntu` (ASUS ROG STRIX B650-A GAMING WIFI, BIOS 2613, Intel `igc` `eno1`).

**Root cause**: `ErP Ready` (a.k.a. EuP / "Deep Sleep" / "Deep S5") in BIOS cuts +5VSB standby power to the PCIe/NIC in S4/S5 to meet the EU ErP <1 W off-state regulation. In **S3** the NIC keeps standby power regardless, so WoL works — which is exactly why it looks armed-and-working right up until you do a *full* shutdown. The OS-side `wol g` arming is **necessary but not sufficient**: from S5 the firmware must also keep the NIC alive, and ErP switches that off.

**Fix**: In BIOS → APM Configuration:
- `ErP Ready` = **Disabled** ← the load-bearing one
- `Power On By PCI-E / PCI` = **Enabled**
- `Deep Sleep` = **Disabled** (if present)

Re-apply after any BIOS flash — an update resets these to defaults. Confirm by testing S5 explicitly (`ssh box 'sudo poweroff'` then `wake box`). **Isolate first with S3**: `sudo systemctl suspend` then `wake box`; if S3 wakes but S5 doesn't, it's ErP, full stop — don't chase the OS/`ethtool`/driver side, which is already correct.

**Related**: setup + troubleshooting table in `docs/sysadmin/wake-on-lan.md`; OS-side arming is the `wake_on_lan` ansible role (`installWakeOnLan`). Not to be confused with a box that wakes then immediately dies — that's a power fault, see `docs/playbooks/random-hard-poweroff.md` + `crash-blackbox`.
