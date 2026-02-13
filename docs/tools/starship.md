# Starship Prompt

[Starship](https://starship.rs/) is a cross-shell prompt written in Rust, replacing the default oh-my-zsh `robbyrussell` theme.

- **Config file**: `~/.config/starship.toml` (chezmoi source: `dot_config/starship.toml`)
- **ZSH init**: `~/.config/zsh/tools/01_starship.zsh`
- **Ansible role**: `starship` (brew on macOS, official installer on Linux, user-level fallback for noRoot)
- **Dependencies**: Nerd Fonts (Hack Nerd Font installed by `nerdfonts` role)

## Quick Start

```bash
chezmoi apply     # deploys config + installs starship via ansible
exec zsh          # reload shell to see the new prompt
```

## Presets

Starship ships with built-in presets that change the entire look:

```bash
# List all available presets
starship preset --list

# Apply a preset (overwrites starship.toml)
starship preset nerd-font-symbols -o ~/.config/starship.toml    # full Nerd Font icons
starship preset pastel-powerline -o ~/.config/starship.toml      # Powerline-style segments
starship preset tokyo-night -o ~/.config/starship.toml           # dark color scheme
starship preset plain-text-symbols -o ~/.config/starship.toml    # ASCII fallback (no Nerd Fonts)
```

After trying a preset, run `chezmoi apply` to restore the chezmoi-managed version.

Preview all presets: <https://starship.rs/presets/>

## Module Configuration

Modules control what information appears in the prompt. Edit `dot_config/starship.toml` (or `chezmoi edit ~/.config/starship.toml`).

### Commonly Useful Modules

| Module | Description | Default |
|--------|-------------|---------|
| `[directory]` | Current path | enabled, truncated to 3 levels |
| `[git_branch]` | Git branch name | enabled |
| `[git_status]` | Dirty/staged/ahead/behind | enabled |
| `[python]` | Python version + virtualenv | enabled (auto-detected) |
| `[nodejs]` | Node.js version | enabled (auto-detected) |
| `[rust]` | Rust version | enabled (auto-detected) |
| `[conda]` | Conda environment name | enabled (works with `CONDA_CHANGEPS1=false`) |
| `[docker_context]` | Docker context | enabled |
| `[cmd_duration]` | Command execution time | enabled, shows when > 2s |
| `[character]` | Prompt character (`❯`) | green on success, red on error |

### Disabled by Default (Worth Enabling)

```toml
# Show clock on the right
[time]
disabled = false
format = "[$time]($style) "
time_format = "%H:%M"

# Show username/hostname (auto-shows over SSH)
[username]
show_always = false    # only show over SSH

[hostname]
ssh_only = true

# Kubernetes context
[kubernetes]
disabled = false

# Memory usage
[memory_usage]
disabled = false
threshold = 75         # only show when usage > 75%

# Battery (laptop)
[battery]
disabled = false

# AWS / GCP / Azure profile
[aws]
[gcloud]
[azure]
```

### Command Duration

```toml
[cmd_duration]
min_time = 2_000           # show when command takes > 2 seconds
format = "took [$duration]($style) "
show_milliseconds = false
```

## Prompt Layout

### Two-Line Prompt

The default config uses `add_newline = true` which adds a blank line between prompts. The `[line_break]` module separates info from the input line:

```toml
# Info on line 1, input cursor on line 2
format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$python\
$nodejs\
$rust\
$conda\
$line_break\
$character"""
```

### Right-Side Prompt

Display less critical info on the right edge of the terminal:

```toml
right_format = "$time$cmd_duration"
```

## Custom Modules

Create custom modules for project-specific or workflow-specific info:

```toml
# Show current tmux session name
[custom.tmux]
command = "tmux display-message -p '#S' 2>/dev/null"
when = "test -n \"$TMUX\""
format = "[$output]($style) "
style = "bold cyan"

# Show active pueue task count
[custom.pueue]
command = "pueue status --json 2>/dev/null | jq '[.tasks[] | select(.status == \"Running\")] | length'"
when = "command -v pueue"
format = "[$output tasks]($style) "
style = "yellow"
```

## Integration Notes

- **oh-my-zsh**: Still loaded for plugins (git aliases, autosuggestions, syntax-highlighting). Only the theme is disabled (`ZSH_THEME=""`).
- **Conda**: `CONDA_CHANGEPS1=false` is set in `04_conda_mamba.zsh`, so starship's `[conda]` module handles env display.
- **tmux2k**: tmux status bar is independent of starship; no conflicts.
- **Nerd Fonts**: Hack Nerd Font Mono is configured in Alacritty. If using a terminal without Nerd Fonts (e.g., SSH to ubuntu_server), apply the `plain-text-symbols` preset.

## Suggested Experience Order

1. **Apply and verify** — `chezmoi apply && exec zsh` (5 min)
2. **Try presets** — find a visual base you like (10 min)
3. **Tune modules** — add `cmd_duration`, `time`, etc. (15 min)
4. **Adjust layout** — two-line prompt, right_format (as needed)
5. **Custom modules** — extend for your workflow (advanced)

Steps 1-2 are enough for daily use. Steps 3-5 can be done incrementally.

## References

- Configuration: <https://starship.rs/config/>
- All presets: <https://starship.rs/presets/>
- All modules: <https://starship.rs/config/#prompt>
