# Wake-on-LAN (remote power-on)

Sysadmin question: **can I power this box on over the network** instead of
walking to it and pressing the button?

This page documents the `wake` CLI + `wakeonlan` (the **active / sender** side)
and the `wake_on_lan` ansible role (chezmoi prompt `installWakeOnLan`, the
**passive / receiver** side). It is the flip side of
[random-hard-poweroff.md](../playbooks/random-hard-poweroff.md) — that one is
"why did this box power *off* by itself"; this one is "power it back *on*".

> **Wired Ethernet only.** WoL over Wi-Fi needs WoWLAN + AP cooperation and is
> out of scope. The receiver side is **Linux only**; the sender runs anywhere
> (the `wake` CLI is pure-stdlib Python, works on macOS too).

## How it works (30 seconds)

- A **magic packet** is `6×0xFF` followed by the target MAC repeated 16×, sent
  as a UDP **broadcast** to port 9.
- The target NIC, kept alive on **standby power**, watches every frame for that
  pattern and, on a match, pulls the board out of sleep (S3) or off (S5).
- **Two independent things must both be true**, and they fail independently:
  1. the NIC is **armed** in the OS — `ethtool -s <if> wol g` (does *not*
     persist across reboots on its own → we install a systemd unit);
  2. **firmware** keeps the NIC on standby power and honours the wake — a BIOS
     setting, not something the OS can do.

## Active side — send the packet (any machine)

The in-house **`wake`** CLI resolves a host name to a MAC and broadcasts:

```bash
wake david-ubuntu          # look up MAC in ~/.config/wake/hosts.toml, send
wake de:ad:be:ef:12:34     # a raw MAC works with no config entry
wake --list                # show configured hosts
wake host -b 10.0.0.255    # override the broadcast address
wake host -c 5             # 5 packets instead of the default 3
```

Hosts live in `~/.config/wake/hosts.toml` (seeded once by chezmoi, mode 0600;
real MACs stay in this **private** file, never in the repo):

```toml
[hosts.david-ubuntu]
mac       = "de:ad:be:ef:12:34"   # target NIC MAC (`ip link` / `ethtool -P eno1`)
broadcast = "192.168.31.255"      # optional; your LAN's directed broadcast
# port    = 9                     # optional (default 9)
```

`wake` always hits `255.255.255.255` **and** the host's directed broadcast
(some networks drop one or the other). It is pure stdlib — no dependency on the
`wakeonlan` binary — so it works on a fresh box. The upstream **`wakeonlan`**
(installed by `networking_tools`) is the equivalent primitive:

```bash
wakeonlan de:ad:be:ef:12:34
wakeonlan -i 192.168.31.255 de:ad:be:ef:12:34   # directed broadcast
```

## Passive side — make a box wakeable (Linux)

Turn on the chezmoi prompt **`installWakeOnLan`** (or the `server-linux`
bundle). The `wake_on_lan` role then, on `chezmoi apply`:

1. installs **ethtool**;
2. drops a templated **`wol@.service`** systemd unit;
3. auto-detects every wired NIC that advertises magic-packet support and
   **enables `wol@<iface>.service`** for it — so `ethtool -s <if> wol g` is
   re-applied on every boot (the arming is otherwise lost on reboot).

Do it by hand on a one-off box:

```bash
sudo apt install -y ethtool
sudo tee /etc/systemd/system/wol@.service >/dev/null <<'UNIT'
[Unit]
Description=Enable Wake-on-LAN (magic packet) on %i
Requires=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -s %i wol g
[Install]
WantedBy=sys-subsystem-net-devices-%i.device
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now wol@eno1.service   # your wired NIC
```

**Verify the NIC is armed** (this is the single most useful check):

```bash
sudo ethtool eno1 | grep -i wake-on
#   Supports Wake-on: pumbg     ← must contain 'g' (magic packet)
#   Wake-on: g                  ← must be 'g', not 'd' (disabled)
```

If `Supports Wake-on` has no `g`, the NIC/driver can't do magic-packet WoL and
no amount of config will help.

## BIOS / firmware — required for wake-from-OFF (S5)

Waking from a **full shutdown** needs the board to keep NIC standby power after
power-off. In BIOS (ASUS shown; names vary by vendor):

| Setting | Value | Why |
|---|---|---|
| **Power On By PCI-E / PCI** | **Enabled** | lets the NIC's PME signal power the board on |
| **ErP Ready** / **EuP** | **Disabled** | ErP cuts NIC standby power in S4/S5 — the #1 cause of "works from suspend, dead from shutdown" |
| **Deep Sleep** / **Deep S5** | **Disabled** | same idea, another name |

A BIOS update resets these — re-apply them after flashing. Firmware can't be set
from Ansible, which is why this stays a manual checklist.

## Suspend (S3) vs full shutdown (S5)

Isolate the variable when testing: **S3 (suspend) wakes with just the OS arming**
(no BIOS change), because the NIC never loses standby power. **S5 (full off)
additionally needs the BIOS settings above.** So:

```bash
# prove the OS/NIC/packet path first, no BIOS needed:
ssh box 'sudo systemctl suspend'   # then, from another host:  wake box
# then, after the BIOS checklist, test the real thing:
ssh box 'sudo poweroff'            # then:  wake box
```

A cold-boot wake takes ~30–70 s to answer ping (POST + boot) — that's normal.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Wake-on: d` after reboot | arming didn't persist | enable `wol@<iface>.service` (or the role) |
| `Supports Wake-on` lacks `g` | NIC/driver can't do magic packet | different NIC, or check driver |
| Wakes from **suspend** but not **shutdown** | BIOS ErP Ready enabled | disable ErP / Deep Sleep |
| Nothing wakes it | Wi-Fi (not wired), or firewall drops broadcast, or box on a different L2 | use wired NIC; send to the subnet's directed broadcast; be on the same LAN |
| Wakes then immediately powers off | that's not WoL — see [random-hard-poweroff.md](../playbooks/random-hard-poweroff.md) | run `crash-blackbox` |

## Files

- Sender: [`dot_dotfiles/bin/executable_wake`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_dotfiles/bin/executable_wake) · config `~/.config/wake/hosts.toml` (template `dot_config/wake/create_private_hosts.toml`)
- Receiver: `dot_ansible/roles/wake_on_lan/` (prompt `installWakeOnLan`) → `/etc/systemd/system/wol@.service`
- Package: `wakeonlan` via `networking_tools`; `ethtool` via `wake_on_lan`
- Sibling: [random hard power-offs](../playbooks/random-hard-poweroff.md) · [`crash-blackbox`](../tools/crash-blackbox.md)
