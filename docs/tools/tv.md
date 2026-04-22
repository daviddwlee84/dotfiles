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

Source file: [`dot_config/television/cable/logs.toml`](../../dot_config/television/cable/logs.toml). Full toolbelt writeup: [log-tools.md](log-tools.md).

**Source cycling** (`Ctrl+S`):

1. Project-local logs under `$PWD` — `.log` / `.ndjson` / `.jsonl` via `fd -HI`
2. User + system log dirs — `~/.cache/**/*.log`, `~/Library/Logs` on macOS, `/var/log/*.log` / `syslog*` / `messages*` (readable only)
3. `journalctl --output=short-iso -n 2000` — Linux systemd journal recent lines (falls back to an empty source otherwise)

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

All actions `cd ~/.ansible` and export `ANSIBLE_CONFIG=$HOME/.ansible/ansible.cfg`, matching the manual invocation pattern in `CLAUDE.md`. OS default: `macos.yml` on Darwin, `linux.yml` otherwise.

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

Columns are `Menu | Command | Alias | Description | Notes`. Leave the alias column blank (`| |`) if there's no oh-my-zsh alias; prefix with `*` if you're adding a custom function that lives in `dot_config/zsh/10_aliases.zsh`. See `docs/zsh/aliases.md` for the full OMZ alias reference.

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
