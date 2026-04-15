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
| `prefix + C` | Switch to Catppuccin |
| `prefix + T` | Switch to tmux2k |

Both entries also live in the `prefix + Space` popup menu.

### First-time caveat

Only the active theme's plugin is declared to TPM at config load time. The first time you flip to the other theme, the theme file's auto-clone hook fetches the repo, then the explicit `run` loads it. If the status bar still looks off after `prefix + C` / `prefix + T`:

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

Current defaults:

- **Left**: `session` → `directory`
- **Right**: `application` → `user` → `host` → `date_time`

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

1. **Switch to Catppuccin**: `prefix + C` — the default theme doesn't render a bandwidth segment at all.
2. **Pin the interface** in `dot_config/tmux/theme.tmux2k.conf`:

   ```tmux
   set -g @tmux2k-network-name "en0"       # macOS Wi-Fi
   # set -g @tmux2k-network-name "wlan0"   # typical Linux Wi-Fi
   # set -g @tmux2k-network-name "eth0"    # typical Linux wired
   ```

   Find the right name with `ip -br link` (Linux) or `ifconfig` / `networksetup -listallhardwareports` (macOS).
3. **Drop the bandwidth segment**: remove `bandwidth` from `@tmux2k-right-plugins`, keeping only `network time`.

See upstream [2kabhishek/tmux2k](https://github.com/2kabhishek/tmux2k) issues for progress.

### Switching themes leaves residual styling

Some tmux options (colors, pane-border-style, etc.) persist on the server after a plugin sets them. Our theme files reset `status-left/right` and `window-status-*` before composing, which covers the visible status bar, but deeper style overrides may linger. Cleanest workaround:

```bash
tmux kill-server && tmux
```
