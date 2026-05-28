# ping-monitor — record ping over time and flag spikes

A small bash tool that pings a target on an interval, colour-flags latency
**spikes**, and prints a summary (min/avg/max, p50/p95/p99, spike count, loss)
on Ctrl-C. A full log is written to `~/ping-monitor-YYYYmmdd-HHMMSS.log`.

It exists because the most useful first step in diagnosing "my Wi-Fi gaming
lags in bursts" is to **ping your own gateway** for a while: a clean baseline
with periodic huge spikes points at the local wireless medium, not the ISP or
the game server. See [WiFi latency spikes](../playbooks/wifi-latency-spikes.md).

## Install

Deployed automatically by chezmoi as `~/.dotfiles/bin/ping-monitor`. Pure bash,
no dependencies; works on macOS and Linux (it picks the right `ping` timeout
flag per platform).

## Usage

```bash
ping-monitor [TARGET] [SPIKE_MS] [INTERVAL_S]
ping-monitor -g | --gateway [SPIKE_MS] [INTERVAL_S]

# Examples
ping-monitor                 # default gateway, flag >100ms
ping-monitor -g 10           # gateway, flag anything >10ms (local-link test)
ping-monitor 8.8.8.8 150 0.5 # upstream host, >150ms, every 0.5s
pinggw                       # alias for `ping-monitor --gateway`
```

- **TARGET** — host/IP. Omit (or use `-g`/`--gateway`) to auto-detect the
  default gateway.
- **SPIKE_MS** — latency at/above which a sample is flagged (default `100`).
  For a gateway/local-link test, drop this to `~10`.
- **INTERVAL_S** — seconds between pings (default `1`).

Output is colour-coded: dim = normal, yellow = approaching the threshold, red =
spike or loss.

## Reading the result

```
min/avg/max     : 1.3 / 44.0 / 408.2 ms
p50/p95/p99     : 2.0 / 282.2 / 345.4 ms
spikes          : 66  (>10ms)
```

A **low p50 with a high p95/p99** is the signature of bursty spikes (the case
this tool is built to catch) — the link is fine *most* of the time but stalls
periodically. A uniformly high baseline instead points at distance / routing /
an overloaded upstream.

## See also

- [WiFi latency spikes](../playbooks/wifi-latency-spikes.md) — the full
  diagnostic workflow this tool feeds into.
- [`reyee`](reyee.md) — inspect/adjust a Ruijie/Reyee router from the CLI.
- [Networking tools](networking.md) — `gping`, `mtr`, `trippy` and friends.
