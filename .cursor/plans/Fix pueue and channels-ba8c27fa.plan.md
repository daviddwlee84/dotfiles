<!-- ba8c27fa-cf2e-4152-92a1-9d350276bcf0 -->
---
todos:
  - id: "fix-read"
    content: "Replace `read -n1` with `read -r _` in pueue.toml follow action"
    status: pending
  - id: "fix-channels-preview"
    content: "Replace `cat` with `bat` (+ fallback) in channels.toml preview"
    status: pending
isProject: false
---
# Fix Pueue Follow Action and Channels Preview

## Bug 1: `read -n1` fails in zsh

TV uses `$SHELL` to execute commands. Since `$SHELL` is `zsh`, the `read -n1` (a bash-ism) fails with `zsh:read:1: bad option: -1`. Confirmed by:

```
zsh -c 'echo test | read -n1 x'  # -> zsh:read:1: bad option: -1
```

**Fix in** `dot_config/television/cable/pueue.toml` line 75:

Replace `read -n1` with `read -r _` (POSIX-portable, waits for Enter in both bash and zsh).

```
# Before
command = "... echo '[Press any key to exit]'; read -n1"

# After  
command = "... echo '[Press Enter to exit]'; read -r _"
```

## Bug 2: channels.toml preview uses plain `cat`

**Fix in** `dot_config/television/cable/channels.toml` line 20:

Replace `cat` with `bat -n --color=always` for syntax-highlighted TOML, with a `cat` fallback if bat is missing.

```toml
# Before
command = "cat ~/.config/television/cable/'{split: :0}'.toml"

# After
command = "bat -n --color=always ~/.config/television/cable/'{split: :0}'.toml 2>/dev/null || cat ~/.config/television/cable/'{split: :0}'.toml"
```

Both files then get deployed via `chezmoi apply`.
