# television (tv) Quick Reference

[television](https://github.com/alexpasmantier/television) — blazing-fast TUI fuzzy finder with pluggable "channels".

Custom channels: `dot_config/television/cable/` (chezmoi-managed)

---

## Basic Usage

```bash
tv                   # Open interactive picker (default channel)
tv <channel>         # Open a specific channel, e.g. tv sesh
tv list-channels     # List all available channels
tv --help            # List all flags
```

From tmux: `prefix + T` opens the sesh channel as a popup (see [Tmux Integration](#tmux-integration)).

---

## Community Channels

tv has a built-in channel package manager. Run once after install (and periodically to update):

```bash
tv update-channels
```

This downloads [community-maintained channels](https://alexpasmantier.github.io/television/community/channels-unix) into `~/.config/television/cable/`. It:

- **Skips** channels whose requirements aren't met on your system (e.g. `apt-packages` on macOS)
- **Skips** channels that already exist (won't overwrite custom channels)
- Covers git, docker, k8s, brew, cargo, GitHub, sesh, tmux, and many more

Notable community channels: `sesh`, `git-branch`, `git-log`, `git-stash`, `git-diff`, `brew-packages`, `docker-containers`, `gh-issues`, `gh-prs`, `just-recipes`, `zoxide`, `zsh-history`, `env`, `dirs`, `files`, `text`.

---

## Custom Channels

### `tools` channel

Parses `~/.config/docs/tools/cli-tools.md` at runtime (deployed via chezmoi from `dot_config/docs/tools/`). The markdown file is the single source of truth — edit it to add or update tools.

Open with `tv tools` or `prefix + U` in tmux.

| Key | Action |
|-----|--------|
| `Enter` | Execute selected tool immediately |
| `Ctrl+/` | Toggle preview panel (tldr or `--help`) |

For pasting an invocation to the shell buffer (with trailing space for tools that need arguments), use the fzf ZLE widget instead: **Alt+T** in any zsh session.

---

### `lan-devices` channel

Fuzzy-search devices on the local subnet with open ports, MAC/vendor, hostname (rDNS + mDNS), ping RTT, and last-seen timestamp. Backed by `~/.config/television/lan-scan.sh`, which writes results incrementally to `~/.cache/tv/lan-devices.tsv` and per-host nmap detail to `~/.cache/tv/lan-ports/<ip>.txt`. The channel uses `watch = 2.0`, so rows stream into the picker as the background scan progresses (state column: `discovered` → `scanning` → `scanned`).

Open with `tv lan-devices`, or run a synchronous scan first with the `lanscan` shell alias.

**Sudo-gated with fallback:** when passwordless sudo is available (`sudo -n true`), the script uses `arp-scan -lgq` for the richest MAC/vendor data. Otherwise it falls back to `nmap -sn` ping sweep + OS ARP cache (`arp -an` on macOS, `ip neigh` on Linux). Vendor lookup for the fallback path uses nmap's `nmap-mac-prefixes` OUI database.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| All devices | Every discovered host, sorted by IP (default) |
| With open ports | Only rows whose port count is ≥ 1 |
| Fresh only | Hosts seen within the last 5 minutes |

**Preview cycling** (`Ctrl+F`):

1. Cached nmap service detail (fast, from `~/.cache/tv/lan-ports/<ip>.txt`)
2. Live `nmap -sV -Pn -F` rescan (blocking, ~10–30 s)
3. ARP + rDNS + mDNS + ping metadata

**Keybindings** (`Alt+` namespace avoids tmux/TV conflicts):

| Key | Action |
|-----|--------|
| `Enter` | Full `nmap -sV -A` in execute mode |
| `Alt+R` | Rescan ports on selected host + reload |
| `Alt+F` | Rescan full subnet (discover + ports) + reload |
| `Alt+D` | Re-discover only (no port scan) + reload |
| `Alt+S` | SSH to selected host |
| `Alt+H` | Open `http://<ip>` in the system browser |
| `Alt+C` | Clear scan cache + reload |
| `Ctrl+Y` | Copy IP to clipboard (OSC 52 over SSH) |

**Cache layout:**

```
~/.cache/tv/
├── lan-devices.tsv         # one row per device (watched by tv)
├── lan-ports/<ip>.txt      # nmap -sV output per host
├── lan-scan.log            # scan progress log
└── lan-scan.lock/          # mutex directory (removed on exit)
```

Requires `nmap`; `rustscan` and `arp-scan` are used when present (all part of the `networking_tools` ansible role).

---

### `logs` channel

Fuzzy-browse log files on the machine with colorful previews. Open with `tv logs`.

Source file: [`dot_config/television/cable/logs.toml.tmpl`](../../dot_config/television/cable/logs.toml.tmpl) (chezmoi template — the journalctl cycle below is only rendered on Linux). Full toolbelt writeup: [log-tools.md](log-tools.md).

**Source cycling** (`Ctrl+S`):

1. Project-local logs under `$PWD` — `.log` / `.ndjson` / `.jsonl` via `fd -HI`
2. User + system log dirs — `~/.cache/**/*.log`, `~/Library/Logs` on macOS, `/var/log/*.log` / `syslog*` / `messages*` (readable only)
3. **Linux only** — `journalctl --output=short-iso -n 2000` for systemd journal recent lines. Templated out on macOS because journalctl output lines are not file paths and the preview/Enter/Alt+T actions can't act on them (a dedicated `tv journalctl` channel would be the follow-up).

**Preview cycling** (`Ctrl+F`):

1. Colorful tail via [`tailspin`](https://github.com/bensadeh/tailspin) — `tail -n 500 FILE | tspin --print`; falls back to raw `tail` when `tspin` is missing
2. Plain [`bat`](https://github.com/sharkdp/bat) view — `bat --style=plain --color=always --line-range=:500` for unbiased comparison

**Keybindings:**

| Key | Action |
|-----|--------|
| `Enter` | Open in `lnav` (falls back to `ccze -A \| less -R`, then plain `less -R`) |
| `Alt+T` | Follow with `tspin --follow` (or `tail -F \| tspin --print` on older tailspin) |
| `Alt+E` | Open in `$EDITOR` |
| `Ctrl+Y` | Copy file path to clipboard (OSC 52 over SSH) |

Requires `fd` (part of the `base` ansible role). Tailspin, lnav, ccze are part of `devtools`.

---

### `services` channel

Cross-platform fuzzy picker for systemd services (Linux) and launchd jobs (macOS), with tailspin-colored log previews and Alt-key lifecycle actions. Open with `tv services`.

Source file: [`dot_config/television/cable/services.toml.tmpl`](../../dot_config/television/cable/services.toml.tmpl) (chezmoi template — Linux and macOS get different `systemctl` vs `launchctl` bodies). Full writeup including symbol legend and sudo caveats: [services.md](services.md).

**Source cycling** (`Ctrl+S`):

1. Running only — active services, system + user merged
2. All loaded — active + inactive + failed among runtime-known units
3. Failed only — crashed / non-zero exit
4. User-scope only — `systemctl --user` / macOS `gui/$UID/` domain
5. **Installed on-disk** — every unit file / `.plist` on disk, with enablement badges (`✓ Enabled` / `○ Disabled` / `— Static` / `⊘ Masked` on Linux; `● Loaded` / `○ On-disk` on macOS). This is the "configured but not enabled" discovery view — land on a `○ Disabled` row, hit `Alt+L`, done.

**Preview cycling** (`Ctrl+F`):

1. Colorful log tail via tailspin — `journalctl -u NAME -n 500` on Linux; tails `StdoutPath` from `launchctl print` on macOS (prints a helpful message when no stdout is configured, rather than blocking on `log show`).
2. Status / details — `systemctl status` / `launchctl print`.

**Keybindings:**

| Key | Action |
|-----|--------|
| `Enter` | Follow live log (`journalctl -fu` / `tail -F StdoutPath \| tspin` or `log stream`) |
| `Alt+R` | Restart (auto-sudo when scope=system) |
| `Alt+S` | Stop (`systemctl stop` / `launchctl bootout`) |
| `Alt+T` | Start (`systemctl start` / `launchctl kickstart` with bootstrap-by-search fallback) |
| `Alt+U` | Reload (`reload-or-restart` / `launchctl kickstart`) |
| `Alt+D` | Show full status in pager |
| `Alt+E` | Edit unit file / plist in `$EDITOR` |
| `Alt+L` | Toggle enable-on-boot |
| `Ctrl+Y` | Copy service name to clipboard |

All mutating actions auto-prepend `sudo` when the row's scope column is `system`. Actions run in `execute` mode so the sudo password prompt is visible if needed.

Deeper platform-specific channels (`tv systemd` with timers/sockets/targets + mask/daemon-reload; `tv launchd` with plist-on-disk sources + bootstrap/bootout) are planned follow-ups — see [`services.md`](services.md) for the full roadmap.

No new dependencies — uses `systemctl`/`journalctl` (base systemd) on Linux, `launchctl`/`log` (macOS built-in) on Darwin, plus `tspin` from `devtools`.

---

### `mac-procs` channel (macOS-only)

Fuzzy-pick the heaviest macOS processes by **compressed-aware** memory (`top -l 1 -o mem`, matches Activity Monitor's "Memory" column). Open with `tv mac-procs`.

Source file: [`dot_config/television/cable/mac-procs.toml.tmpl`](../../dot_config/television/cable/mac-procs.toml.tmpl) (chezmoi template gated on `eq .chezmoi.os "darwin"`, so the channel only appears on macOS hosts).

**Why this exists vs the generic `kill-process` channel**: `kill-process` sorts by RSS via `ps -axm`. On Apple Silicon, RSS does NOT include compressed or swapped pages — a process leaking 2 GB of compressed data shows as 100 MB in the RSS view. `mac-procs` uses `top -o mem` whose `mem` column is compressed-aware. See [macos-swap.md](macos-swap.md) for the full mental model.

Source cycling (`Ctrl+S`):

1. **Top by Memory** (compressed-aware, default) — matches Activity Monitor
2. **Top by CPU** — what's burning the fan / battery
3. **Top by virtual size** (`ps -axm` VSZ) — fragmented apps / Electron sniffing

Preview cycling (`Ctrl+F`):

1. `vmmap -summary <pid>` — VM region breakdown (no sudo)
2. `ps -p <pid> -o ...` — pid/ppid/user/etime/state/full command
3. `lsof -p <pid> | head -40` — top open files / sockets

Keybindings: only `Enter` (passthrough) for now. Alt-key actions (kill, force-kill, footprint dump) are deliberately deferred — usage will be evaluated via the alias-only flow first; see the channel file header for candidate slots and the AGENTS.md "Keyboard shortcuts" matrix before claiming any new Alt slot.

No new dependencies — `top`, `vmmap`, `ps`, `lsof` are all macOS built-ins.

---

### `ansible` channel

Browse the ansible playbooks / roles / tags shipped in `dot_ansible/` (deployed to `~/.ansible/`). Useful for quickly running a playbook, syntax-checking after edits, or copying the full `ansible-playbook` invocation to paste into a shell.

Open with `tv ansible`.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| Playbooks | `~/.ansible/playbooks/*.yml` (base, linux, macos) |
| Roles | Every role directory under `~/.ansible/roles/` |
| Tags | Unique tag names extracted from all playbooks |

**Preview cycling** (`Ctrl+F`):

1. Playbook → YAML via `bat`; role → `tasks/main.yml` + `defaults/main.yml`; tag → playbook lines that declare it
2. Playbook → tag list within the file; role → directory listing; tag → roles referencing the tag

**Keybindings** (`Alt+` namespace avoids tmux/TV conflicts):

| Key | Action |
|-----|--------|
| `Enter` | Run playbook (`ansible-playbook playbooks/<name>.yml`); on role/tag, run OS-default playbook filtered by `--tags <name>` |
| `Alt+C` | Syntax check (`--syntax-check`) |
| `Alt+D` | Dry run (`--check`) |
| `Alt+T` | Run OS-default playbook filtered by the selected tag/role |
| `Alt+E` | Edit file in `$EDITOR` (playbook YAML or role's `tasks/main.yml`) |
| `Alt+V` | Open role directory in `yazi` (roles source only) |
| `Ctrl+Y` / `Alt+Y` | Copy full `ansible-playbook ...` command to clipboard (OSC 52 over SSH) |

All actions `cd ~/.ansible` and export `ANSIBLE_CONFIG=$HOME/.ansible/ansible.cfg`, matching the manual invocation pattern in [`docs/this_repo/architecture.md`](../this_repo/architecture.md#ansible-usage). OS default: `macos.yml` on Darwin, `linux.yml` otherwise.

---

### `git-ops` channel

Fuzzy-search the full VSCode Source Control + GitLens command palette (~150 entries: pull/push, commit variants incl. amend, undo-last-commit, branch, rebase, cherry-pick, stash, tags, worktrees, submodule, config). Backed by `~/.config/docs/tools/git-ops.md` — the markdown table is the single source of truth; edit the table to change the channel.

Each row also shows the matching **oh-my-zsh `git` plugin alias** (`gc!`, `gcam`, `gpf!`, `gst`, `grhh`, `gstp`, …) or repo-custom function (prefixed `*`, e.g. `*gcam-amend`, `*gundo`, `*lg`). That means you can fuzzy-search either by semantic name (`amend`, `undo`, `force push`), by the full `git …` invocation, **or** by the alias you half-remember — any of them lands on the same row.

Open with `tv git-ops` (standalone) or press `Alt+I` in zsh to paste the selected command straight into the shell prompt.

| Key | Action |
|-----|--------|
| `Enter` | Print selected command to stdout — captured by the `Alt+I` ZLE widget and inserted into `LBUFFER` |
| `Ctrl+Y` | Copy command to clipboard (overrides TV default; pbcopy / wl-copy / xclip / OSC 52 fallback) |
| `Alt+E` | Confirm-prompt then `eval` the command (y/N); aborts by default on anything else |
| `Ctrl+F` | Cycle preview: matching row from `git-ops.md` ↔ `git help <subcommand>` |
| `Ctrl+O` | Toggle preview panel (TV global) |

> `Alt+E` (not `Ctrl+E`) is used for execute so that TV's global `Ctrl+E = go_to_input_end` muscle memory is preserved inside the picker.

Destructive rows (`commit --amend`, `reset --hard`, `push --force`, `branch -D`, `clean -fd`, `stash drop/clear`, `tag -d` on remote, rebase, etc.) are prefixed with `⚠` in the display line and trigger a red warning banner under `Alt+E`.

Use-cases this solves:

- "What's the exact `git commit --amend --no-edit` flag again?" — type `amend` or `gcn!`, Enter, done.
- "How do I undo the last commit without losing work?" — type `undo` or `gundo`, you see all three variants (soft / mixed / hard with the destructive tag).
- "Which alias force-pushes safely?" — type `force`, see `gpf` (with-lease, safe) next to `gpf!` (raw `--force`, destructive).
- Copy a command into a Cursor chat or a teammate's Slack without typing — `Ctrl+Y`.
- `git worktree`, `git submodule`, `git cherry-pick` — the commands nobody remembers the flags for.

Adding a new command: append a row to the appropriate section of `dot_config/docs/tools/git-ops.md`:

```markdown
| Menu Label | `git some-command --flag` | `gsf` | Short description | destructive |
```

Columns are `Menu | Command | Alias | Description | Notes`. Leave the alias column blank (`| |`) if there's no oh-my-zsh alias; prefix with `*` if you're adding a custom function that lives in `dot_config/zsh/10_aliases.zsh`. See `docs/shells/aliases.md` for the full OMZ alias reference.

Re-run `chezmoi apply` (md is deployed to `~/.config/docs/tools/`); no channel reload needed — it's parsed at runtime.

---

### `pueue` channel

Interactive task manager for [pueue](https://github.com/Nukesor/pueue) — fuzzy-search tasks, preview logs, and pause/resume/kill/restart without leaving the picker. Parses `pueue status --json` at runtime. Requires `pueue` and `jq`.

Open with `tv pueue`. Auto-refreshes every 2 seconds.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| All tasks | Every task, newest first (default) |
| Active only | Running + Queued + Paused tasks |
| Failed only | Tasks that exited non-zero |
| Groups overview | Pueue groups with status and parallelism |

**Task management** (all `Alt+key` to avoid conflicts with TV built-ins and tmux):

| Key | Action |
|-----|--------|
| `Enter` | Follow running task / view finished task log / show group status |
| `Alt+E` | Edit task command in `$EDITOR` (stashed/queued only) |
| `Alt+P` | Pause task |
| `Alt+R` | Resume/start task |
| `Alt+K` | Kill task |
| `Alt+T` | Restart task (in-place) |
| `Alt+X` | Remove task from list |
| `Alt+L` | Clean all finished tasks |

**Clipboard:**

| Key | Action |
|-----|--------|
| `Alt+Y` | Copy raw command to clipboard |
| `Alt+A` | Copy full `pueue add -w <path> -g <group> ...` command to clipboard |

`Alt+Y` copies just the original command string. `Alt+A` reconstructs a full reproducible `pueue add` invocation including working directory, group, label, priority, and dependencies — useful for re-queuing or sharing tasks.

**Group filtering:**

| Key | Action |
|-----|--------|
| `Enter` | On groups view: show `pueue status -g <name>` text overview |
| `Alt+G` | Open a filtered view showing only the selected task's group |

`Alt+G` extracts the group name from the selected entry and launches a new `tv` instance with `--source-command` filtered to that group. The filtered view has preview but not the full action keybindings. Quit to return to the main `tv pueue` channel. Enter on the groups source (cycle 4) shows a quick text overview via `pueue status -g`.

**Preview** (`Ctrl+F` cycles):

1. Task log output (`pueue log <id> --lines 200`) — piped through `tspin --print` when [tailspin](log-tools.md) is installed, for colored timestamps/levels/IPs/URLs. Falls back to raw output on fresh installs.
2. Full JSON task details (timing, dependencies, result — envs stripped for readability)

**Implementation notes:**

- All action keybindings use `Alt+` to avoid shadowing TV built-ins (`Ctrl+P`/`Ctrl+K` for navigation, `Ctrl+A`/`Ctrl+E` for input cursor, `Ctrl+R` for reload, etc.) and tmux root-table bindings (`C-h/j/k/l` for vim-tmux-navigator). Requires terminal to send Option as Meta (Ghostty: `macos-option-as-alt = left`).
- Uses jq's `@tsv` for output formatting — avoids TOML/shell escape conflicts with jq's `\(...)` interpolation syntax
- Clipboard actions are cross-platform: pbcopy (macOS), wl-copy (Wayland), xclip (X11), with OSC 52 fallback for remote SSH sessions (works through tmux with `set-clipboard on`)
- `Ctrl+Y` is overridden in the pueue channel to copy just the raw command (TV's default `ctrl-y` copies the full display line including ID, status, and group)
- `pueue edit` only works on stashed/queued tasks (pueue limitation); for running/finished tasks use `Alt+Y` to copy and re-add manually

---

### `azure` channel

Fuzzy-search Azure resources via `az` CLI with per-resource actions: restart / start / power-off / deallocate / rotate-public-IP / SSH / open-in-portal / delete / copy-id / switch-subscription. Backed by three helper scripts under `~/.config/television/` (`azure-source.sh`, `azure-preview.sh`, `azure-rotate-ip.sh`). Requires `az` (ansible `iac_tools` tag) and `jq`; the channel is automatically skipped on hosts without either.

Open with `tv azure`. No auto-refresh — `az` calls are too slow to watch; hit `Ctrl+R` to reload.

**Login gate:** if `az account show` fails, the channel shows a single synthetic row (`login · not-logged-in`). Press `Enter` to run `az login`, then `Ctrl+R` to reload.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| Resource Groups | `az group list` (default) |
| Virtual Machines | `az vm list -d` — name, RG, location, power state |
| Public IPs | `az network public-ip list` — ipAddress + FQDN |
| NICs + NSGs | Union of `az network nic list` and `az network nsg list` |
| All resources | `az resource list` — generic fallback when you know a name but not its type |

**Preview cycling** (`Ctrl+F`):

1. `az <kind> show -o yaml` pretty-printed via `bat` when available
2. `az <kind> show -o json` for copy-paste / `jq` piping

**Keybindings** (`Alt+` namespace avoids tmux/TV conflicts):

| Key | Action | Works on |
|-----|--------|----------|
| `Enter` | Show full resource (`az … show` in execute mode); on the login row runs `az login` | all |
| `Alt+R` | Restart VM | vm |
| `Alt+S` | Start VM | vm |
| `Alt+P` | Power-off VM (still billed) | vm |
| `Alt+D` | Deallocate VM (not billed) | vm |
| `Alt+I` | **Rotate public IP** — keeps the FQDN, swaps the IP | vm |
| `Alt+H` | SSH via `az ssh vm` (requires the `ssh` az extension) | vm |
| `Alt+O` | Open resource in Azure Portal (`open` / `xdg-open` / `wslview`) | all |
| `Alt+X` | Delete with y/N confirm | rg / vm / pip / nic / nsg / res |
| `Alt+U` | Switch subscription (fzf picker of `az account list`) | all |
| `Ctrl+Y` / `Alt+Y` | Copy resource id to clipboard (pbcopy / wl-copy / xclip / OSC 52 fallback) | all |

Actions internally `case $kind` on the row's kind field, so wrong-kind keys (e.g. `Alt+R` on an RG row) print a 1-second "only applies to VMs" toast and no-op — same idiom as the `ansible` channel's role-only `Alt+V`.

**Rotate Public IP** (`Alt+I`) calls `~/.config/television/azure-rotate-ip.sh <rg> <vm>`, a stateless port of [`DockerCompose-V2Ray/scripts/az_rotate_ip.sh`](https://github.com/daviddwlee84/DockerCompose-V2Ray/blob/main/scripts/az_rotate_ip.sh). It:

- Resolves VM → NIC → PIP → DNS label live via `az` (no `.secrets/` state file).
- Refuses to run when `SSH_CONNECTION` is set (detaching the PIP would sever the SSH session before reattach).
- Requires Standard SKU (Basic retired 2025-09-30) with a `dnsSettings.domainNameLabel` — nothing to preserve otherwise.
- 5-step: detach → delete → recreate with same `--dns-name` → reattach → `dig +short <fqdn>` verify.
- `AZ_YES=1 azure-rotate-ip.sh <rg> <vm>` skips the confirm prompt (useful for scripting; the TV channel runs interactively so the prompt is fine).

Use case: the GFW bans an Azure VM's public IP. Rotating keeps the `*.cloudapp.azure.com` FQDN, the TLS cert, the client configs, everything — the only change is the underlying IP.

**Multi-subscription:** `Alt+U` pipes `az account list` through `fzf` so you can `az account set` without leaving the picker, then reloads the source. The `[ui].input_header` simply reads "Azure" — resolving the current subscription at channel-init time is cheap but not worth the UX complexity of refreshing it after `Alt+U`.

**Non-goals (v1):** provisioning (`az vm create` stays in the V2Ray repo), teardown beyond `Alt+X`, and Windows-specific VM operations.

---

### `clash` and `clash-api` channels

Clash now ships as two TV channels:

- `tv clash` — YAML-backed browsing of the resolved Clash profile.
- `tv clash-api` — live browsing of the external-controller API.

Both channels reuse the same helpers under `~/.config/television/`:

- `clash-parse.py` — PyYAML parser with `uv run --script` shebang.
- `clash-source.sh` — TSV source emitter for both YAML-backed and API-backed rows.
- `clash-preview.sh` — preview dispatcher for YAML, API, latency, and context views.

Requires `curl` (base role). `uv` is required for YAML parsing and optional for pure env-driven API use. `bat` and `jq` are optional.

#### `tv clash`

Open with `tv clash`.

**YAML discovery** (first match wins):

1. `$CLASH_CONFIG` — explicit override, hard-fails if the path does not exist.
2. `~/.config/clash/profiles/list.yml` → active `profiles/<time>.yml`
3. `~/.config/clash/config.{yaml,yml}`
4. `~/.config/mihomo/config.{yaml,yml}`
5. `~/Library/Application Support/{clash,mihomo}/config.{yaml,yml}` (macOS)

The important split is:

- YAML rows (`proxies`, `proxy-groups`, `rules`, `summary`, `server`, `path`) come from the resolved profile, usually the active `profiles/<time>.yml`.
- Controller operations still prefer the runtime `external-controller` from the live Clash config, because profile files commonly keep stale controller ports like `127.0.0.1:9090` while the running app uses a different local port.

Examples:

```bash
tv clash
CLASH_CONFIG="$HOME/.config/clash/profiles/1731944239843.yml" tv clash
```

If a resolved YAML has no `proxies[]`, `proxy-groups[]`, or `rules[]`, the channel emits a single informative `none` row instead of TV's generic "no stdout" placeholder. When no config exists at all, `Enter` on the `none` row still seeds `~/.config/clash/config.yaml` and opens `$EDITOR`.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| Proxies | One row per `proxies[]` entry — `name`, `type`, `server:port`, compact `tls/udp/network/cipher` flags |
| Proxy Groups | One row per `proxy-groups[]` entry — `name`, `type`, current first member, `N members` |
| Rules | One row per `rules[]` entry, indexed `#NNNN` |
| Summary | Top-level YAML scalars plus `proxies.count` / `proxy-groups.count` / `rules.count` |
| API | Live controller health via `/version`, runtime `/configs`, and `/connections` counters |

**Preview cycling** (`Ctrl+F`):

1. Main — selected YAML block (API rows switch to controller JSON)
2. Latency — `/proxies/:name/delay` when the controller is reachable, else TCP + ping fallback
3. Meta — YAML context: groups referencing a proxy, group YAML, selected rule, or API detail

#### `tv clash-api`

Open with `tv clash-api`.

Controller discovery:

1. `$CLASH_CONTROLLER` / `$CLASH_SECRET`
2. Runtime `external-controller` from the local Clash config
3. Reachable Docker/local controller at `127.0.0.1:9090`

Examples:

```bash
tv clash-api
CLASH_CONTROLLER=192.168.222.207:9090 tv clash-api
CLASH_CONTROLLER=192.168.222.207:9090 CLASH_SECRET=mytoken tv clash-api
```

`tv clash-api` does not add an in-UI host switch. Remote targeting stays env-driven on purpose.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| Proxies | Live `/proxies` leaf entries (rows without `all`) |
| Proxy Groups | Live `/proxies` selector-style entries (rows with `all`) |
| Rules | Live `/rules` entries |
| Summary | `/version`, `/configs`, `/connections` |

**Preview cycling** (`Ctrl+F`):

1. Main — controller JSON for the selected proxy, group, rule, or summary row
2. Latency — `/proxies/:name/delay` for proxies and `/proxies/:group` detail for groups
3. Meta — proxy-group references, group members/history, and nearby rules

**Shared keybindings** (`Alt+` namespace avoids tmux/TV conflicts):

| Key | Action | Applies to |
|-----|--------|------------|
| `Enter` | Show full detail for the selected row | both |
| `Alt+T` | Latency test | both |
| `Alt+S` | Switch a proxy-group's selection to the highlighted proxy | both |
| `Alt+C` | Close all connections (`DELETE /connections`) | both |
| `Alt+R` | Reload Clash config (`PUT /configs?force=true`) | both |
| `Alt+D` | Open `http://<host>/ui` or fall back to `yacd.haishan.me` | both |
| `Ctrl+Y` | Copy `server:port` when YAML can resolve it, else copy the row name | both |
| `Alt+Y` | Copy the row name | both |
| `Alt+E` | Edit the resolved YAML config in `$EDITOR` | `clash` only |

Notes:

- All mutating actions (`Alt+S/C/R`) probe `/version` first; unreachable controllers no-op with a clear message.
- If no explicit env override is set, a stale or missing YAML `external-controller` falls back to `127.0.0.1:9090` when that API answers. This covers Docker Clash containers published as `0.0.0.0:9090->9090/tcp`.
- `tv clash-api` can reload a remote controller only when `CLASH_CONFIG` points at a config path that is meaningful on that controller host. If the remote host differs from the local runtime controller and no explicit `CLASH_CONFIG` is provided, `Alt+R` refuses with an explanation instead of sending a bad local path.

**Redaction hardening**

The sample configs users paste into `.specstory/history/`, `.cursor/plans/`, `.claude/plans/`, and `.opencode/plans/` often contain vmess UUIDs and Azure proxy hostnames. Three rules in [`.gitleaks.toml`](../../.gitleaks.toml) catch them with `secretGroup = 1`, so `scripts/redact_secrets.py` rewrites only the sensitive capture:

- `clash-vmess-uuid` — `uuid: 41871a7c-…` → `uuid: 418...c56`
- `clash-vmess-share-link` — `vmess://<base64>` → `vme...XYZ`
- `azure-cloudapp-hostname` — `<vm>.<region>.cloudapp.azure.com` → truncated host only

Raw IPv4 proxy servers are intentionally not redacted by default; they are too noisy against legitimate examples of public DNS and CDN endpoints.

---

### `sesh` channel (community)

Provided by `tv update-channels`. Source cycling through session types and directory search, with connect/kill actions.

**Source cycling** (use `Ctrl+S` to cycle):

| Source | Description |
|--------|-------------|
| All sessions | `sesh list --icons` (default) |
| Tmux sessions | `sesh list -t --icons` |
| Configured sessions | `sesh list -c --icons` |
| Zoxide directories | `sesh list -z --icons` |
| File search | `fd -H -d 2 -t d -E .Trash ~` |

**Action keybindings:**

| Key | Action |
|-----|--------|
| `Enter` | Connect to selected session |
| `Ctrl+D` | Kill selected tmux session + refresh list |

**Preview:** `sesh preview` — right panel.

---

## Tmux Integration

| Binding | Action |
|---------|--------|
| `prefix + T` | Open sesh channel as a television popup |
| `prefix + g` | Open sesh session picker via fzf (alternative) |

> For the full tmux session management keybinding reference, see `docs/tools/tmux/keybindings.md`.

---

## Keybinding Conflicts with tmux

TV's default `ctrl-h/j/k/l` bindings conflict with tmux's `vim-tmux-navigator` root-table pane navigation (`C-h/j/k/l`). The managed config (`dot_config/television/config.toml`) resolves this:

| Default | Action | Remapped to | Notes |
|---------|--------|-------------|-------|
| `ctrl-j` | select_next_entry | _(removed)_ | Use `down` or `ctrl-n` |
| `ctrl-k` | select_prev_entry | _(removed)_ | Use `up` or `ctrl-p` |
| `ctrl-h` | toggle_help | `alt-h` | Mnemonic, no conflicts |
| `ctrl-l` | toggle_layout | `alt-l` | Overridden in pueue channel (clean) |

All other TV defaults (`ctrl-s`, `ctrl-f`, `ctrl-r`, `ctrl-y`, etc.) are kept since they don't conflict with tmux root-table bindings.

---

## Tips

- `Tab` / `Shift+Tab` — navigate results
- `Ctrl+P` / `Ctrl+N` — move up/down (vim users)
- `Alt+H` — toggle help panel (remapped from `ctrl-h` to avoid tmux conflict)
- Channels are defined as `.toml` files in `~/.config/television/cable/`
- Global config at `~/.config/television/config.toml` (chezmoi-managed from `dot_config/television/config.toml`)
- Run `tv update-channels` to get/update community channels
- Custom channels in this repo live at `dot_config/television/cable/` (deployed via chezmoi, won't be overwritten by `update-channels`)
- See [tv vs fzf](tv-vs-fzf.md) for comparison and channel best practices
