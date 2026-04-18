# TV Channel: LAN Devices + Open Ports

## Context

Users already have a rich set of networking tools installed via the `networking_tools`
ansible role (`arp-scan`, `nmap`, `rustscan`, `doggo`, …) but reach for them only
via ad-hoc shell commands. A Television channel would give a unified fuzzy-searchable
view of what's on the LAN, each device's open ports/services, and metadata
(MAC/vendor/hostname/latency). The main UX challenge is that a full scan is slow
(seconds–minutes), so the channel must stream partial results into the picker
rather than blocking on each open.

Design decisions confirmed with user:
- **Sudo-gated with fallback**: use `arp-scan`/`nmap -O` when passwordless sudo
  is available (`sudo -n true`), otherwise fall back to no-sudo path
  (`nmap -sn` ping sweep + `arp -a`/`ip neigh` + rustscan TCP connect).
- **Cached + on-demand rescan**: scan runs in background, writes incrementally
  to a cache file; TV reads the cache with `watch = 2.0` so rows appear live.
- **Columns shown**: IP, MAC, vendor, hostname (rDNS + mDNS), open-port count +
  top services, last-seen, latency.

## Files to add

### 1. `dot_config/television/cable/lan-devices.toml.tmpl` — new channel
Template so platform-specific commands (`arp -a` on macOS vs `ip neigh` on Linux)
and binary-availability checks can be baked in at `chezmoi apply` time.

Structure mirrors `dot_config/television/cable/pueue.toml` (pattern validated in
exploration):
- `[source]` reads `~/.cache/tv/lan-devices.tsv`; `watch = 2.0`; `no_sort = true`
  so rows stay ordered by IP. Source cycling (`Ctrl+S`):
  1. All discovered devices (default)
  2. Only devices with open ports
  3. Only devices scanned in last 5 min (`last_seen` fresh)
- `display` / `output` use `{split:\t:N}` against TSV columns:
  `ip \t mac \t vendor \t hostname \t port_count \t top_services \t latency_ms \t last_seen_iso \t state`
  (`state` ∈ `discovered|scanning|scanned|stale`, used for the `...` placeholder
  while a host's ports are still being scanned).
- `[preview]` cycling (`Ctrl+F`):
  1. Cached per-host port/service detail from `~/.cache/tv/lan-ports/<ip>.txt`
  2. Live `nmap -sV {ip}` (blocking, only on explicit cycle)
  3. Raw ARP + rDNS + mDNS lookup (fast)
- `[keybindings]` (Alt+ namespace to avoid tmux/TV conflicts, per repo
  keybinding rules in CLAUDE.md):
  - `Enter` → full `nmap -sV -A` in `execute` mode
  - `Alt+R` → rescan single host (`actions:rescan_host` + `reload_source`)
  - `Alt+F` → rescan full subnet (`actions:rescan_all` + `reload_source`)
  - `Alt+S` → open ssh to host (`ssh {ip}`)
  - `Alt+H` → open http(s)://host in `$BROWSER` (or `w3m` in execute mode)
  - `Ctrl+Y` → copy IP to clipboard (reuse the `_clip` helper pattern from
    `pueue.toml` so OSC 52 works over SSH)

Template conditionals to handle:
- On Linux: `ip neigh show` as ARP source when no sudo; on macOS: `arp -an`.
- Skip the channel entirely if neither `nmap` nor `rustscan` is installed
  (emit a file that prints an install hint so `tv lan-devices` stays discoverable).

### 2. `dot_config/television/scripts/executable_lan-scan.sh.tmpl` — scan orchestrator
New helper directory under the TV config; the channel's actions invoke this
script. Deployed to `~/.config/television/scripts/lan-scan.sh` (executable via
`executable_` prefix, chezmoi convention). Responsibilities:

- **Locking**: `flock` on `~/.cache/tv/lan-scan.lock` so only one scan runs at a time.
- **Subnet detection**:
  - macOS: parse `route -n get default` → iface → `ifconfig $iface inet`
  - Linux: `ip -4 route show default` → iface → `ip -4 addr show $iface`
  - Fall back to `192.168.1.0/24` only if detection fails; log warning to cache.
- **Sudo gating**: `sudo -n true 2>/dev/null` decides between:
  - Privileged path: `sudo -n arp-scan -lgq --plain` (best MAC + vendor coverage)
  - Unprivileged path: `nmap -sn -n --min-rate 1000 <cidr>` to populate ARP
    cache, then read `arp -an` / `ip neigh show`.
- **Enrichment (parallel, per-host via `xargs -P`)**:
  - Reverse DNS: `getent hosts <ip>` (Linux) or `dscacheutil -q host -a ip <ip>` (macOS)
    with `dig +short -x <ip>` as fallback.
  - mDNS: `dns-sd -q <ip>.in-addr.arpa. PTR` on macOS (timeboxed), or
    `avahi-resolve -a <ip>` on Linux if available. Gracefully skipped otherwise.
  - Ping RTT: single `ping -c 1 -W 1 <ip>` → parse `time=`.
  - Vendor: from arp-scan output when privileged; otherwise OUI lookup against
    `/usr/share/nmap/nmap-mac-prefixes` (nmap ships this file on both platforms).
- **Incremental write**: script `mv` a tmp file over `~/.cache/tv/lan-devices.tsv`
  after each enrichment batch, so TV's `watch = 2.0` picks up progress.
- **Port scanning**: second pass after discovery — for each host with state
  `discovered`, run `rustscan -a <ip> -g --timeout 2000` (or
  `nmap -F --open <ip>` if rustscan missing) with `-P4` concurrency. Results
  written to `~/.cache/tv/lan-ports/<ip>.txt`; main TSV row updated with
  `port_count`, `top_services` (comma-joined top 3), and `state=scanned`.
- **CLI modes**:
  - `lan-scan.sh discover` — discovery + enrichment only (fast, ~2–5 s)
  - `lan-scan.sh ports [--host <ip>]` — port-scan all or a single host
  - `lan-scan.sh all` — discovery then ports (default, used by `Alt+F`)
  - `lan-scan.sh clean` — purge cache

### 3. `dot_config/zsh/tools/50_networking.zsh` — add convenience aliases
Append to the existing networking aliases file (already hosts `arpscan`,
`pingsweep`, `portscan`), adding:
- `lanscan='~/.config/television/scripts/lan-scan.sh all'`
- `tv-lan='tv lan-devices'`

### 4. Docs updates
- **`docs/tools/tv.md`** — add a "Custom channels" subsection entry for
  `lan-devices`: summary, keybindings, cache path.
- **`docs/tools/networking.md`** — under "What's on my network?" add a pointer
  to `tv lan-devices` / `lanscan`, with a note that it auto-detects sudo.
- **`README.md`** — one-line mention under TV channels (per CLAUDE.md's
  "Maintaining README.md" rule).
- **`docs/zsh/aliases.md`** — add rows for the two new aliases (required by
  CLAUDE.md's "Maintaining Custom Aliases" rule).

## Patterns reused from existing code

- `watch = 2.0` + TSV cache file — exact pattern from
  `dot_config/television/cable/pueue.toml:45` adapted to a file-backed source
  instead of a re-run command.
- `@tsv`-style safe interpolation via `{split:\t:N}` — from `pueue.toml:43-44`.
- Source cycling + preview cycling — from `pueue.toml:37-52`.
- `Alt+key` action namespace to dodge tmux/TV conflicts — per
  `docs/tools/tv.md` and CLAUDE.md keybinding table.
- `_clip` helper for clipboard with OSC 52 SSH fallback — pattern from
  `pueue.toml` `copy_command` action.
- `executable_*` chezmoi prefix — same as other scripts under
  `dot_config/` (e.g., responsive tmux script under `dot_config/tmux/`).
- Platform branching via chezmoi templates (`{{ if eq .chezmoi.os "darwin" }}`)
  — already used throughout the repo (e.g., `run_onchange_after_20_ansible_roles.sh.tmpl`).

## Verification

1. `chezmoi diff` then `chezmoi apply` — confirm:
   - `~/.config/television/cable/lan-devices.toml` exists.
   - `~/.config/television/scripts/lan-scan.sh` exists and is executable.
2. Shell: `~/.config/television/scripts/lan-scan.sh discover` — cache file
   `~/.cache/tv/lan-devices.tsv` should populate within ~5 s and contain at
   least the default gateway.
3. `tv lan-devices` — picker opens, rows appear incrementally while
   `lan-scan.sh all` runs in the background. Try:
   - `Ctrl+S` cycles source variants.
   - `Ctrl+F` cycles preview variants.
   - `Alt+R` on a row triggers single-host rescan; row updates within ~2 s.
   - `Alt+F` triggers full rescan.
   - `Ctrl+Y` copies IP (verify with `pbpaste` / `wl-paste`).
4. Sudo-fallback smoke test: `sudo -k` to clear cached credentials, rerun
   `tv lan-devices` — it should auto-fall-back to the no-sudo path without
   prompting. Then `sudo -v` and rerun — privileged path should kick in and
   MAC/vendor columns should improve.
5. Cross-platform: run on macOS and at least one Linux host
   (ubuntu_desktop profile) to confirm subnet detection + ARP parsing both work.
6. TV syntax-check: `tv --list-channels` includes `lan-devices`.
7. Docs/README diff is consistent with CLAUDE.md maintenance rules.
