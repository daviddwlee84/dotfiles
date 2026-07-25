# `peon-ping-setup` escapes a faked `$HOME` and writes into your real `~/.config`

**Symptoms** (grep this section):
- You ran `peon-ping-setup` (or `install.sh`) with `HOME=/tmp/something` to
  sandbox it, and it still created files in your **real** home
- New unmanaged files appear at `~/.config/opencode/plugins/peon-ping.ts`
  (a symlink), `~/.config/opencode/peon-ping/config.json`, and
  `~/.config/opencode/peon-ping/peon-icon.png`
- The installer's own summary output prints a real absolute path
  (`/Users/<you>/.config/opencode/...`) that does **not** sit under the `HOME`
  you set
- `chezmoi status` suddenly shows unmanaged entries under a directory chezmoi
  otherwise manages (`~/.config/opencode/plugins/` also holds
  `workmux-status.ts` and `herdr-agent-state.js`)

**First seen**: 2026-07
**Affects**: peon-ping 2.35.1 (`peon-ping-setup`, `libexec/install.sh`), any
machine where `XDG_CONFIG_HOME` is exported
**Status**: upstream behaviour; avoid by never running the installer on a
managed machine (this repo declares the hooks itself — see
[`docs/tools/agent-sounds.md`](../docs/tools/agent-sounds.md))

## Symptom

Trying to discover what the installer writes, without letting it touch anything:

```sh
P=/tmp/peon-probe; mkdir -p "$P/.claude"
HOME="$P" peon-ping-setup --packs=sc2_scv
```

The Claude half is correctly contained — `$P/.claude/hooks/peon-ping/` and
`$P/.claude/settings.json` are written under the fake root. But the output ends
with:

```
OpenCode:
  Plugin:  /Users/david/.config/opencode/plugins/peon-ping.ts
  Config:  /Users/david/.config/opencode/peon-ping/config.json
```

— the **real** paths.

## Root cause

The installer derives its Claude root from `$HOME` (so faking `HOME` works
there), but resolves the OpenCode root from **`$XDG_CONFIG_HOME`**, which this
repo exports as `/Users/<you>/.config` (and which does not follow a re-pointed
`HOME`). Any per-IDE adapter keyed off an XDG variable escapes the sandbox the
same way.

`HOME` alone is therefore **not** a sufficient sandbox for this installer.

## If you need to probe it anyway

Override both, and audit afterwards:

```sh
P=/tmp/peon-probe; mkdir -p "$P/.claude" "$P/.config"
HOME="$P" XDG_CONFIG_HOME="$P/.config" peon-ping-setup --packs=sc2_scv
```

Or use the upstream reroot flag, which moves the whole install to a
tool-agnostic root instead of `~/.claude`:

```sh
peon-ping-setup --openpeon --no-rc
```

Then verify nothing leaked before trusting the result:

```sh
chezmoi status ~/.config/opencode/      # must be empty
git -C "$(chezmoi source-path)" status  # must be clean
```

## Cleanup

The three leaked files are safe to remove; they are recreated by the ansible
role when a tier that needs them is selected:

```sh
rm -f  ~/.config/opencode/plugins/peon-ping.ts
rm -rf ~/.config/opencode/peon-ping
```

Do **not** blanket-remove `~/.config/opencode/plugins/` — `workmux-status.ts`
and `herdr-agent-state.js` live there too and are chezmoi-managed.

## Why this matters here

It is the concrete reason this repo never runs `peon-ping-setup` on a managed
machine and declares the hooks itself instead. Full design:
[`docs/tools/agent-sounds.md`](../docs/tools/agent-sounds.md).

## Related

- [`claude-hud-shows-raw-model-id`](claude-hud-shows-raw-model-id.md) — another
  "same config, different result" trap in the Claude hook/statusline area
