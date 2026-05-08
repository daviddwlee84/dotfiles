# Firewall & network exposure

Three questions every sysadmin asks weekly:

1. **What's blocking / allowing inbound traffic?** (firewall rules)
2. **What ports are bound?** (listening sockets — the actual attack surface)
3. **Who's connected to me right now?** (established connections)

This page covers all three with backend-agnostic helpers and a single
`tv firewall` channel.

## Backends

Linux fragmented this space; this repo's helpers detect whichever is
installed and use it.

| Backend | Distro defaults | Query | Common confusion |
|---|---|---|---|
| **nftables** (`nft`) | Modern Debian / Ubuntu / RHEL 9+ | `nft list ruleset` | New API, replaces iptables; `iptables-nft` is a shim |
| **iptables** | Older / non-systemd Linux | `iptables -S` / `iptables -L -n -v` | Two flavours: legacy and `iptables-nft` (talks to nftables under the hood) |
| **ufw** | Ubuntu desktop / server (frontend) | `ufw status verbose` | Wraps iptables / nftables; high-level allow/deny syntax |
| **firewalld** | RHEL / CentOS / Fedora (frontend) | `firewall-cmd --list-all` | Zone-based; `firewall-cmd` modifies live rules + persists |
| **pf** | macOS, FreeBSD, OpenBSD | `pfctl -s rules` | macOS has pf but disables it by default — see "macOS quirks" below |
| **Application Firewall (ALF)** | macOS only | `socketfilterfw --getglobalstate` | Per-app allow/deny; layer-7, NOT a packet filter |

**Hard truth**: a host can have *both* a packet filter (nftables / pf)
and an application-level controller (ufw / firewalld / ALF) installed.
The packet filter wins on contradiction. Always check the lowest level
when debugging "why is this port unreachable?".

## Listening sockets ≠ firewall rules

`fw-rules` shows **what packets the kernel will drop**. `fw-listening`
shows **what processes are willing to receive**. A port can be
listening *and* firewall-blocked — `nmap` from outside will see it as
`filtered`, not `closed`. Both views are needed.

| Question | Right tool |
|---|---|
| "Is port 22 reachable from the internet?" | `fw-rules` (firewall) + nmap from outside |
| "Why does my service complain port 8080 is in use?" | `fw-port 8080` (find the process) |
| "What's exposed on this box?" | `fw-listening` (every bound socket + owning process) |
| "Who's connected to me right now?" | `fw-conn` (active connections) |

## Helpers in this repo

| Function | What it answers | Sudo? |
|---|---|---|
| `fw-rules` | All firewall rules from every detected backend | Yes |
| `fw-listening` | Bound TCP+UDP sockets with owning process | Yes for full process info |
| `fw-conn [--all]` | Established TCP connections (or all states) | Yes for process info |
| `fw-port <port>` | Who is using `<port>`? (LISTEN + ESTABLISHED) | Yes |

`tv firewall` cycles 4 sources via `Ctrl+S`: rules → listening → established → defaults/policy. Preview pane resolves ports to services and walks the process parent tree.

## Common queries

```bash
# Routine survey: rules + listeners + connections in one screen
fw-rules | head -40
fw-listening
fw-conn

# Something's listening on 8080 — what?
fw-port 8080

# Interactive browse
tv firewall          # Ctrl+S to cycle source, Enter for full context
```

## Detection / hardening cookbook

### "What's actually exposed to the network?"

```bash
fw-listening | grep -vE '127\.0\.0\.1|::1'
```

Filter out loopback. The remaining lines are the real attack surface.
For each entry decide:

- Is the port supposed to be exposed? (sshd / web — yes; postgres /
  redis — usually no, only via VPN)
- Is the firewall blocking it externally? (`fw-rules` to confirm)

### "Did someone open a port without telling me?"

If `installAuditd` is on, the baseline rule set watches
`/etc/ufw`, `/etc/firewalld`, `/etc/nftables.conf` (extend
`/etc/audit/rules.d/00-baseline.rules` if you want them — they're not
in the default set yet; see [auditd.md](auditd.md)). Then:

```bash
audit-file /etc/ufw/
audit-file /etc/nftables.conf
```

Without auditd, fall back to filesystem mtime:

```bash
ls -la /etc/ufw /etc/nftables.conf /etc/firewalld 2>/dev/null
```

### "Is sshd reachable from the wrong network?"

```bash
fw-rules | grep -i 'dport.*22\|port.*22'
```

Cross-check with `sshd_config` `ListenAddress` and your `Match Address`
blocks. The firewall and sshd both have to agree to block; one alone
isn't enough.

## macOS quirks

- **pf is installed but disabled by default**. `sudo pfctl -e` enables;
  `sudo pfctl -d` disables. Most macOS users never touch it.
- **Application Firewall (System Settings → Network → Firewall) is
  per-app, not per-port**. It only works for incoming connections to
  programs running on macOS, not for forwarding or for outbound traffic.
- **No `ss(8)`**. The `fw-listening` / `fw-conn` helpers fall back to
  `lsof -nP -iTCP -sTCP:LISTEN`. Slower but works.
- **Little Snitch / LuLu** are popular third-party outbound firewalls;
  they have their own UIs and aren't reachable from `pfctl`.

## See also

- [Sessions and login](sessions.md) — Level 0; the firewall decides who
  even gets to *try* to log in
- [Helpers in this repo](helpers.md) — full reference table
- [Cookbook recipe 5](cookbook.md#5-i-suspect-someone-ran-nmap-from-this-box--level-2--level-3) — `nmap` from this box
