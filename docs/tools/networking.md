# Networking CLI Tools

Optional role (`installNetworkingTools`). Install via `chezmoi init --force` and enable the prompt.

## Tools

| Tool | Binary | Purpose | Sudo at runtime? |
|------|--------|---------|-------------------|
| [nmap](https://nmap.org/) | `nmap` | Port scanning, host discovery, OS detection, service enumeration | Some features (OS detection, SYN scan) |
| [arp-scan](https://github.com/royhills/arp-scan) | `arp-scan` | Fast Layer 2 host discovery with OUI vendor lookup | Yes (raw sockets) |
| [mtr](https://www.bitwizard.nl/mtr/) | `mtr` | Real-time combined ping + traceroute | Some modes |
| [iperf3](https://iperf.fr/) | `iperf3` | Network bandwidth/throughput testing between two hosts | No |
| [doggo](https://github.com/mr-karan/doggo) | `doggo` | Modern DNS lookup (replaces dig/nslookup), DoH/DoT/DoQ | No |
| [HTTPie](https://httpie.io/) | `http` / `https` | Modern HTTP client, nicer than curl for API testing | No |
| [gping](https://github.com/orf/gping) | `gping` | Ping with a real-time graph | No |
| [trippy](https://github.com/fujiapple852/trippy) | `trip` | Modern TUI traceroute with rich visualization | Yes (raw sockets) |
| [bandwhich](https://github.com/imsnif/bandwhich) | `bandwhich` | Terminal bandwidth utilization per process/connection | Yes (packet capture) |
| [Ookla Speedtest](https://www.speedtest.net/apps/cli) | `speedtest` | Official Ookla internet speed test | No |
| [RustScan](https://github.com/RustScan/RustScan) | `rustscan` | Fast port scanner, feeds results into nmap | No |

## Shell Aliases

Defined in `~/.config/zsh/tools/50_networking.zsh`:

| Alias | Command | Description |
|-------|---------|-------------|
| `ports` | `lsof -i -P -n \| grep LISTEN` | Show all listening ports |
| `myip` | `curl -s https://ifconfig.me` | Show public IP address |
| `localip` | platform-aware | Show local LAN IP address |
| `arpscan` | `sudo arp-scan -l` | Scan local network (Layer 2) |
| `pingsweep` | `nmap -sn <subnet>/24` | Ping sweep local /24 subnet (function) |
| `dns` | `doggo` | DNS lookup shortcut |
| `bw-net` | `sudo bandwhich` | Bandwidth monitor (avoids conflict with `bw` = Bitwarden) |
| `portscan` | `rustscan` | Fast port scan shortcut |

## Common Usage

### What's on my network?

```bash
# Layer 2 ARP scan (most reliable, shows MAC + vendor)
arpscan

# Ping sweep (Layer 3)
pingsweep

# Full scan with OS detection
sudo nmap -sV -O 192.168.1.0/24
```

### Port scanning

```bash
# Quick port scan (rustscan is ~10x faster than nmap alone)
portscan -a 192.168.1.100

# Specific ports with nmap
nmap -p 22,80,443,8080 192.168.1.100

# Service version detection
nmap -sV -p 22,80 192.168.1.100
```

### DNS lookup

```bash
# Basic lookup
dns example.com

# Specific record type
dns example.com MX
dns example.com AAAA

# Use DNS-over-HTTPS
dns example.com --class IN --type A @https://cloudflare-dns.com/dns-query

# Use DNS-over-TLS
dns example.com @tls://1.1.1.1
```

### Diagnostics

```bash
# Real-time traceroute
mtr google.com

# Graphical ping (compare multiple hosts)
gping google.com cloudflare.com 1.1.1.1

# TUI traceroute with rich visualization
trip google.com

# See what's listening on this machine
ports
```

### Bandwidth testing

```bash
# Internet speed test
speedtest

# LAN throughput (need iperf3 on both ends)
# On server: iperf3 -s
# On client:  iperf3 -c <server-ip>

# Monitor per-process bandwidth usage
bw-net
```

### HTTP testing

```bash
# GET request (httpie)
http httpbin.org/get

# POST with JSON
http POST httpbin.org/post name=test value=123

# With headers
http GET api.example.com Authorization:"Bearer token123"
```

## Platform Notes

- **macOS**: All tools installed via Homebrew. `tcpdump` is preinstalled.
- **Linux (with sudo)**: `nmap`, `arp-scan`, `mtr`, `iperf3`, `httpie`, `tcpdump` via apt. Others from GitHub releases to `~/.local/bin`.
- **Linux (noRoot)**: apt tools skipped; `trippy` system-level install skipped. GitHub binary tools still work but `arp-scan`, `bandwhich`, and `trippy` need sudo at runtime for raw socket access.
