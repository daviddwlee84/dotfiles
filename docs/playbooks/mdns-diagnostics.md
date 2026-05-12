# mDNS / Bonjour diagnostics on macOS

When a device on your LAN won't show up by name (`raspberrypi.local`, an
AirPlay receiver, a HomeKit accessory, a network printer, etc.), the cause is
almost always one of:

1. The advertising device isn't actually on the same broadcast domain.
2. The router/AP is dropping multicast or isolating clients.
3. The querying device is on a separate VLAN / guest SSID / different band
   that the router doesn't bridge.
4. A firewall on either end is blocking UDP 5353.

mDNS uses **UDP port 5353** to multicast addresses **`224.0.0.251`** (IPv4)
and **`ff02::fb`** (IPv6). The protocol is link-local — packets carry TTL 255
but routers will not (and should not) forward them across L3 boundaries. Any
"mDNS reflector" / "Bonjour gateway" feature on a router is doing
application-layer relaying, not routing.

The three commands below cover the diagnostic ladder: app-level browse →
direct name resolution → raw packet capture.

## 1. Can you discover services on the LAN?

```sh
dns-sd -B _services._dns-sd._udp local.
```

This is the **meta-query**: it asks every responder on the link "what service
*types* do you advertise?" Each replier should answer with the registered
types it owns (`_airplay._tcp`, `_raop._tcp`, `_companion-link._tcp`,
`_googlecast._tcp`, `_ipp._tcp`, `_workstation._tcp`, `_miio._udp`, etc.).

How to read the output:

| Column | Meaning |
|---|---|
| `A/R` | **A**dd or **R**emove (mDNS records have TTLs and can age out) |
| `if` | macOS interface index — `ifconfig <name>` or `dns-sd -E` to map it |
| `Domain` | Always `.` for link-local — nothing to look at |
| `Service Type` | `_tcp.local.` / `_udp.local.` |
| `Instance Name` | The discovered service type, e.g. `_airplay` |

The trap: **most of what you see is your own Mac**. Apple devices use
**AWDL** (Apple Wireless Direct Link) on a virtual `awdl0` interface, plus
the loopback `lo0`, to advertise their own services peer-to-peer. Those
entries are *not* coming through your router. Map the interface indices
first:

```sh
# Quick interface index → name lookup
ifconfig -l | tr ' ' '\n' | nl
# or, just look at the active Wi-Fi
ifconfig en0 | head -3
```

Filter mentally: ignore everything on `awdl0` and `lo0`; the interesting
rows are on your real Wi-Fi/Ethernet interface (typically `en0` on a Mac).
If the only service types you see on `en0` are coming from your own Mac,
either the LAN really is silent, or multicast isn't reaching you.

## 2. Try resolving a real `.local` hostname

```sh
dns-sd -G v4 <hostname>.local
```

`-G v4` = "Get address info, IPv4 only". Replace `<hostname>.local` with
something you *know* exists — a printer, a Pi, an iPad's name, an Avahi
hostname (`hostname` on the Linux box).

What "working" looks like:

```text
Timestamp     A/R Flags if Hostname        Address      TTL
12:34:56.000  Add 2     6  printer.local.  192.168.1.42 120
```

What "not working" looks like: `...STARTING...` and then nothing — meaning
no responder claimed that name within the protocol's window. Three causes:

- The name doesn't exist (typo, or the device isn't running mDNS).
- The device is on a different L2 segment.
- Multicast is being dropped between you and the device.

A `.local` name that resolves with `dns-sd` but not with `ping` usually
means the macOS firewall is blocking the resolved IP, not an mDNS problem.

## 3. See raw mDNS packets

```sh
sudo tcpdump -i en0 -n udp port 5353
# v6 too, on a Mac with IPv6 link-local:
sudo tcpdump -i en0 -n '(udp port 5353)'
```

This is the ground truth — what's *actually* arriving on your wire/wireless.
Each line is one mDNS packet. The interesting fields:

```
HH:MM:SS.uuuuuu  IP <src>.5353 > 224.0.0.251.5353: <txid> [flags] <Q/A>? <name>
```

Patterns to look for:

- **Outbound `Q?` lines from your own IP** = your queries are leaving fine.
- **Inbound `A?`/`PTR?`/`TXT?` from other LAN IPs to `224.0.0.251`** =
  multicast IS reaching you. mDNS is working.
- **Only your own outbound queries, no replies, ever** = router or AP is
  almost certainly dropping multicast (AP isolation, IGMP snooping with no
  querier, broken multicast-to-unicast conversion, or guest-SSID isolation).
- **Replies arrive but only from one specific device** = that device's
  responder is fine; the *other* devices either aren't running mDNS or
  aren't on this segment.

AirPlay receivers (Apple TV, HomePod, AirPlay-2 capable iOS) flood
distinctive TXT records with `rp*` keys (`rpHA` = HomeKit pairing identifier,
`rpBA` = Bluetooth MAC, `rpVr` = AirPlay version). Spotting `rpHA=` in
tcpdump confirms an AirPlay receiver is broadcasting and you're receiving
it.

`tcpdump`'s end-of-capture summary (`N packets captured, M packets received
by filter, K dropped by kernel`) confuses people: "received by filter" is
**all packets BPF inspected**, not "all packets that matched the filter".
"captured" is the count actually printed. A captured/received ratio of
~1/100 just means port 5353 traffic is a small fraction of total wire
traffic — not that anything was dropped. Only `dropped by kernel > 0`
indicates a buffer overrun.

## Common router-side culprits

| Setting | What to look for | Why it kills mDNS |
|---|---|---|
| AP / client isolation | "AP isolation", "Client isolation", "Intranet access" | Drops *all* L2 frames between wireless clients, multicast included |
| Guest SSID | Anything labelled "Guest" | Almost always isolates guests from the main LAN |
| IGMP snooping | "IGMP snooping" without an IGMP querier | Snooping treats unknown multicast as "no subscribers" → drops it |
| Multicast rate / M2U | "Multicast rate", "Multicast-to-unicast" | Some firmwares mangle or rate-limit 5353 specifically |
| Separate per-band SSIDs | 2.4G and 5G as different SSID names | Devices on different bands may end up on different bridges |
| WAN-side firewall | Upstream router (double-NAT) | Irrelevant for LAN mDNS, but mDNS does NOT cross routers |

If the router exposes a "Bonjour Gateway" / "mDNS reflector" / "AirPlay
Discovery Proxy" toggle and your LAN spans multiple VLANs, that's the
feature you want enabled — it relays mDNS packets across the L3 boundary at
the application layer.

## Xiaomi / MiWiFi specifics

The stock MiWiFi web UI exposes very few of the above knobs. There is no
visible AP-isolation, IGMP-snooping, or multicast-to-unicast toggle. The
only discovery-related toggles are Mi-specific:

- **`miotrelay` (畅快连)** — multicast relay daemon for cross-radio Mi IoT
  discovery. Leave **on** for mDNS-friendly behaviour.
- **`miscan` (AIoT Smart Antenna Auto-Scan)** — scans for unprovisioned Mi
  smart devices on 5G. Independent of generic mDNS.

The [`mi-router`](../tools/mi-router.md) CLI dumps the current state of
both, plus everything else the web UI shows, without needing a browser:

```sh
mi-router mdns      # the two relevant toggles + caveats
mi-router all       # info + wifi + devices + mdns
```

## When you've exhausted these

If `tcpdump` confirms you're sending queries but never receive replies on
`en0`, and you don't have access to the router/AP's advanced settings, the
remaining options are:

1. Wired test — plug into the router via Ethernet and re-run the three
   commands. If wired works and Wi-Fi doesn't, the AP is the culprit.
2. Pcap on the *advertising* device — confirm it's actually transmitting
   mDNS responses on its segment.
3. Flash the router with OpenWrt or similar to expose `ebtables` /
   `igmpproxy` / `avahi-daemon` directly.

## See also

- [`docs/tools/mi-router.md`](../tools/mi-router.md) — read-only inspector
  for MiWiFi routers (the `mdns` subcommand maps directly to this page).
- `man dns-sd`
- `man tcpdump` — `-i any` and `-vv` are useful when narrowing down which
  interface receives mDNS.
- RFC 6762 (mDNS) and RFC 6763 (DNS-SD).
