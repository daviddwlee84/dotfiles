# tmux — Themes

Two themes are installed side-by-side; **Catppuccin is the default**.

| Theme | Status bar | Active option |
|-------|-----------|---------------|
| Catppuccin (mocha, rounded windows) | **top** | `@theme_variant = catppuccin` (default) |
| tmux2k (onedark, with git / cpu / ram + bandwidth / network / time) | **bottom** | `@theme_variant = tmux2k` |

## How theme selection works

The entry point `~/.config/tmux/tmux.conf` resolves the theme in this order:

1. `TMUX_THEME` environment variable (if set when tmux starts).
2. The `@theme_variant` tmux option (persists on the server until `kill-server`).
3. Fallback: `catppuccin`.

Each theme file declares its own TPM plugin, explicitly `run`s that plugin (so `prefix + R` works), and resets `status-left/right` + `window-status-format` before composing its own.

## Switching

### Per-server at launch (shell-side)

```bash
TMUX_THEME=tmux2k tmux        # start tmux in tmux2k
TMUX_THEME=catppuccin tmux    # start tmux in catppuccin
```

Handy aliases:

```bash
alias tmuxc='TMUX_THEME=catppuccin tmux'
alias tmuxt='TMUX_THEME=tmux2k tmux'
```

### Inside a running session

| Keybinding | Action |
|------------|--------|
| `prefix + M-c` | Switch to Catppuccin |
| `prefix + M-t` | Switch to tmux2k |

Both entries also live in the `prefix + Enter` popup menu.

### First-time caveat

Only the active theme's plugin is declared to TPM at config load time. The first time you flip to the other theme, the theme file's auto-clone hook fetches the repo, then the explicit `run` loads it. If the status bar still looks off after `prefix + M-c` / `prefix + M-t`:

1. Press `prefix + I` — TPM will (re)install anything missing.
2. For the cleanest visual result (no leftover style from the previous theme), run `tmux kill-server && tmux`.

## Catppuccin status modules

The v2 plugin ships a set of prebuilt modules in `~/.tmux/plugins/tmux/status/`. Compose `status-left` / `status-right` by appending `#{E:@catppuccin_status_<name>}` entries in `theme.catppuccin.conf`.

| Module | What it shows |
|--------|----------------|
| `session` | Session name |
| `directory` | Current pane's directory (tweak with `@catppuccin_directory_text`) |
| `application` | Foreground command in the active pane |
| `user` | `$USER` |
| `host` | Hostname |
| `date_time` | Date/time (tweak with `@catppuccin_date_time_text`, strftime format) |
| `uptime` | Host uptime |
| `cpu` | CPU load |
| `ram` | RAM usage |
| `battery` | Battery (laptops; silent otherwise) |
| `load` | System load average |
| `gitmux` | [gitmux](https://github.com/arl/gitmux) status (requires `gitmux` binary) |
| `kube` | kubectl context (requires `kubectl`) |
| `weather` / `clima` | Weather (network + `curl`) |
| `pomodoro_plus` | Pomodoro timer |

Current defaults (all shown at full width):

- **Left**: `session` → `directory`
- **Right**: `application` → `user` → `host` → `date_time`

These modules are **responsive** — see [Responsive status bar](#responsive-status-bar-catppuccin) below.

To add `cpu` and `ram` to the right side, for example:

```tmux
set -agF status-right "#{E:@catppuccin_status_cpu}"
set -agF status-right "#{E:@catppuccin_status_ram}"
```

Useful knobs:

```tmux
set -g @catppuccin_directory_text "#{b:pane_current_path}"   # basename (default)
set -g @catppuccin_directory_text "#{pane_current_path}"     # full path
set -g @catppuccin_date_time_text "%Y-%m-%d %H:%M"           # strftime
```

## Responsive status bar (Catppuccin)

The Catppuccin theme adapts its status bar modules to terminal width via
`~/.config/tmux/responsive.sh`. A `client-resized` hook re-runs the script
whenever the terminal is resized, so it works automatically on everything from
a phone terminal to a 4K monitor.

### Width tiers

| Width (columns) | Tier | Left | Right |
|-----------------|------|------|-------|
| >= 120 | wide | session + directory | application + user + host + date_time |
| 80-119 | medium | session + directory | host + date_time |
| < 80 | narrow | session | date_time |

`status-left-length` and `status-right-length` also scale with width (25/40, 40/80, 60/120 respectively) to avoid tmux's default truncation limits.

### Why a shell script instead of pure tmux format conditionals?

Catppuccin module format strings internally contain commas (from
`#{?client_prefix,red,green}` for the prefix-key color indicator). Nesting
these inside another `#{?condition,module,}` ternary breaks tmux's format
parser because it confuses the comma delimiters. A shell script sidesteps this
by running separate `tmux set -agF` commands for each module, avoiding any
format nesting.

### Theme switching

When switching from Catppuccin to tmux2k (`prefix + M-t`), the
`client-resized` hook is automatically removed (`set-hook -gu client-resized`
in `theme.tmux2k.conf`). Switching back to Catppuccin re-registers the hook.

### Customizing tiers

Edit `~/.config/tmux/responsive.sh` (source: `dot_config/tmux/executable_responsive.sh`).
The width thresholds and module assignments are plain bash `if` blocks near the
top of the script.

## Troubleshooting

### Catppuccin shows default green tmux status bar

Means the plugin isn't loaded. Check:

```bash
ls ~/.tmux/plugins/tmux   # should contain catppuccin.tmux
```

If missing, the auto-clone didn't run (e.g. no network on first reload). Fix:

```bash
git clone https://github.com/catppuccin/tmux.git ~/.tmux/plugins/tmux
tmux source-file ~/.tmux.conf
```

Or just press `prefix + I` once inside tmux.

### Bandwidth segment shows `18446744073709551615K` (tmux2k)

That number is `2^64 − 1` — the uint64 wraparound value. It appears when tmux2k's bandwidth helper computes `previous_counter − current_counter` and the subtraction underflows. Common triggers:

- tmux2k's auto-detected interface has no traffic or disappeared (VPN tunnel, `docker0`, a bridge interface, etc.).
- The cached "previous tick" counter is missing on the first refresh after a reload or server restart.

Workarounds (pick one):

1. **Switch to Catppuccin**: `prefix + M-c` — the default theme doesn't render a bandwidth segment at all.
2. **Pin the interface** in `dot_config/tmux/theme.tmux2k.conf`:

   ```tmux
   set -g @tmux2k-network-name "en0"       # macOS Wi-Fi
   # set -g @tmux2k-network-name "wlan0"   # typical Linux Wi-Fi
   # set -g @tmux2k-network-name "eth0"    # typical Linux wired
   ```

   Find the right name with `ip -br link` (Linux) or `ifconfig` / `networksetup -listallhardwareports` (macOS).
3. **Drop the bandwidth segment**: remove `bandwidth` from `@tmux2k-right-plugins`, keeping only `network time`.

See upstream [2kabhishek/tmux2k](https://github.com/2kabhishek/tmux2k) issues for progress.

### Status-left session name doesn't update after `sesh connect`

Symptom: switching session via `sesh connect` (or any `switch-client -t`) leaves the old session name in catppuccin's status-left until you `tmux detach` + `tmux attach`, run `tmux refresh-client -S` manually, or hit `prefix + R` to source the config.

Cause: catppuccin's `@catppuccin_status_session` module stores its text segment via `set -ag` (without `-F`), embedding `#{E:@catppuccin_session_text}` (which expands to `#S`) as a *string reference* inside the variable. When `responsive.sh` then wraps that variable in another `#{E:...}`, the result is triple-nested expansion that tmux's per-client format cache does not invalidate on `client-session-changed`. Reported upstream as [catppuccin/tmux#337](https://github.com/catppuccin/tmux/issues/337) (closed but the staleness path remains).

Fix (already applied in `dot_config/tmux/executable_responsive.sh`): hand-roll the session block using a literal `#S` plus the catppuccin `@thm_*` palette variables, bypassing `@catppuccin_status_session` entirely. The directory and right-side modules still go through catppuccin because they don't reference live per-client state. tmux re-evaluates `#S` on every status redraw, so switching sessions updates immediately without any hooks or `refresh-client` calls.

The variant of this fix that does NOT work: adding `set-hook -g client-session-changed 'refresh-client -S'` or appending `&& tmux refresh-client -S` to sesh bindings. Both fire too early — `run-shell` completes asynchronously after the popup frame redraws over the refresh, so the cached status-left wins. The hand-rolled approach is the only fix that survives the popup race.

### Switching themes leaves residual styling

Some tmux options (colors, pane-border-style, etc.) persist on the server after a plugin sets them. Our theme files reset `status-left/right` and `window-status-*` before composing, which covers the visible status bar, but deeper style overrides may linger. Cleanest workaround:

```bash
tmux kill-server && tmux
```
