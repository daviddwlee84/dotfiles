# Diagnosing periodic Wi-Fi latency spikes

Symptom: a device (often gaming on a phone/tablet) has a fine *average* ping —
say 20–30 ms — but **periodically spikes to hundreds of ms** for a second or
two, then recovers. Throughput is fine; it's the bursty latency that ruins
real-time use.

This page is the diagnostic ladder that isolates *where* the spikes come from,
in order of how cheaply each rung rules things out. The tools referenced are
[`ping-monitor`](../tools/ping-monitor.md), [`tv wifi-scan`](../tools/tv.md),
and (for Ruijie/Reyee routers) [`reyee`](../tools/reyee.md).

## The mental model

A steady-low-with-periodic-huge-spikes pattern is almost never the ISP or the
game server — those show up as a *uniformly* higher baseline or as packet
loss, not as clean 1.5 ms that jumps to 300 ms once every few seconds. Bursty
spikes on an otherwise clean link mean **something local is periodically
stealing airtime or making the radio unavailable**:

- **Co-channel / adjacent interference** — another AP or device sharing your
  channel. Wi-Fi is half-duplex; when the neighbour transmits, you wait.
- **Client-side background scanning** — a laptop/phone briefly leaving the
  channel to scan for other APs (roaming). Only affects that one device.
- **AP-side background scanning / RRM** — the access point periodically going
  off-channel to survey the RF environment (rogue detection, auto-channel,
  cloud "Wi-Fi optimization"). Affects **every** client on that radio, and is
  **independent of which channel you pick**.
- **Wireless repeater / mesh backhaul** — a repeater that talks to the main
  router over the same band halves airtime and stalls periodically.
- **Bufferbloat** — only under load; not the cause of idle-link spikes.

## Rung 1 — ping your own gateway (is it even local?)

```bash
ping-monitor --gateway 10 1     # flag anything >10ms to the first hop
```

The gateway is the **first hop** — your own router. If *that* spikes, the
problem is between you and the router (or the router itself); the internet path
is irrelevant. This single test eliminates the ISP, the GFW, routing, and the
game server in one shot.

- Gateway is clean, only internet targets spike → look upstream (out of scope
  here).
- **Gateway already spikes → it's local.** Continue.

## Rung 2 — is it the wireless medium, or the router?

Repeat the gateway test **over a wired connection** (plug in Ethernet, turn
Wi-Fi off):

```bash
ping-monitor --gateway 10 1
```

- **Wired is clean, Wi-Fi spikes → it's the radio side** (interference,
  scanning, or a repeater). This is the common case.
- Wired *also* spikes → it's the router itself (CPU, firmware, a flooding
  client). Check the router's own diagnostics and client list.

## Rung 3 — is your signal actually good? (rule out distance)

A weak signal causes retries that look like spikes. Check RSSI / noise / SNR:

```bash
# macOS
system_profiler SPAirPortDataType -json | python3 -m json.tool | less
# Linux
iw dev wlan0 link        # or: nmcli -f IN-USE,SSID,SIGNAL,CHAN,FREQ dev wifi
```

Rule of thumb (5 GHz): **RSSI ≥ -60 dBm and SNR ≥ 25 dB is fine.** If you're at
-30 dBm with SNR 60 and *still* spiking, signal strength is **not** the cause —
do not chase it.

## Rung 4 — survey the channel neighbourhood

```bash
tv wifi-scan          # fuzzy-search nearby APs; preview shows per-channel
                      # occupancy + a non-DFS recommendation
wifiscan              # alias: rescan up front
```

Look for **another strong AP on your exact channel** (co-channel) and whether
you're on a **DFS** channel (5 GHz 52–64 / 100–144 — these require radar
detection and add their own pauses).

If you find co-channel contention, move to a clear **non-DFS** channel
(36/40/44/48 or 149/153/157/161/165). On a Ruijie/Reyee router:

```bash
reyee set-channel --band 5g --channel 36          # dry-run first
reyee set-channel --band 5g --channel 36 --yes    # apply (briefly drops Wi-Fi)
```

**Re-test after the change settles** (see the pitfall below). If a clean,
non-DFS channel does **not** help, the cause is channel-independent → it's
scanning (Rung 5).

## Rung 5 — channel-independent spikes = scanning

If you've reached here — gateway spikes, wired is clean, signal is excellent,
channel is clear and changing it didn't help, and **multiple devices spike**
(not just one) — the cause is **periodic off-channel scanning by the AP**, or a
wireless repeater contending for airtime.

To separate the two:

- **Power off / remove the repeater (or extra mesh node)**, let things settle,
  and re-test against the main AP. Still spiking with a single AP → it's the
  main AP's own scanning.
- A wireless repeater sharing the main radio's channel is itself a periodic
  airtime thief; converting it to a **wired backhaul** (or removing it) is the
  fix if it turns out to be the cause.

AP-side background scanning on consumer **cloud-managed** routers
(Ruijie/Reyee "易联" / Ruijie Cloud, some TP-Link/ASUS "AiMesh" RRM, etc.) often
has **no clean off switch** in the UI. The levers that actually help:

1. **Update firmware** — background-scan latency is a known, frequently-patched
   class of bug.
2. **Remove the extra mesh node from the config** (not just power it off) so
   the controller stops periodically hunting for it.
3. **Unbind from cloud management / switch to a local/standalone or AP mode**,
   which disables the cloud's periodic optimization scans.
4. As a last resort, accept it, or replace the AP with one whose scanning is
   configurable (e.g. OpenWrt, where you can disable background scans outright).

## Pitfall: don't measure during a reconfiguration storm

Every channel / mesh / band change triggers a **1–2 minute reconfiguration**
on most APs (Reyee even prints "配置中可能会出现卡顿，属于正常现象"). If you test
*immediately* after a change you're measuring the storm, not steady state — and
you'll wrongly conclude the change "made it worse."

**Always wait ~10 minutes after any change, stay in one spot, then run a long
test** (`ping-monitor --gateway 10 300` for 5 minutes) before drawing a
conclusion. Moving between rooms mid-test also changes which AP and signal
you're on — hold position.

## Case study (this repo's home network)

A real run that produced this page (redacted):

- **Symptom:** iPad gaming, baseline ~25 ms, periodic spikes to ~500 ms.
- **Rung 1:** gateway ping spiked to 40–97 ms (p95 67 ms) — **local**.
- **Rung 3:** Mac on 5 GHz, **RSSI -27 dBm, SNR 67, 866 Mbps** — signal
  perfect, not distance.
- **Rung 4:** a neighbour AP shared the exact channel (ch 52, also DFS). Moved
  the router 52 → 36. **No improvement.** Found the network was **2 Reyee APs**
  (main + a *wireless* repeater); the sub-AP was still on ch 52. Moved it to
  149. **Still no improvement** — and worse right after, because we measured
  inside the reconfiguration storm.
- **Rung 2:** wired gateway ping = **0 spikes, p99 1.4 ms.** Router/LAN/CPU
  fine; it's purely the radio.
- **Rung 5:** powered the repeater **off**, let it settle, re-tested a single
  AP with perfect signal on a clean non-DFS channel → **still p95 282 ms, p99
  345 ms, 66 spikes in 4 minutes.** Channel, signal, co-channel and the
  repeater are all ruled out. Both Mac **and** iPad spike.
- **Conclusion:** periodic off-channel scanning by the cloud-managed (Ruijie
  Cloud / 易联) main AP — channel-independent, all-client, no API/UI toggle.
  Remaining levers: firmware update, remove the mesh node from config, or
  unbind from cloud / switch working mode.

The takeaway: **changing channels is rung 4, not the answer.** When spikes are
channel-independent and hit every device on a perfect link, suspect the AP's
own scanning — and don't trust any single test taken right after a change.
