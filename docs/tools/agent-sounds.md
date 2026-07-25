# Agent completion sounds (`agentSounds`, peon-ping, OpenPeon/CESP)

How a coding agent tells you it finished: a desktop banner, a game-character
voice line, both, or nothing. Chosen per machine with the `agentSounds`
chezmoi prompt.

> **TL;DR** — `agentSounds` gates **hook wiring only**. The `peon` CLI installs
> on every desktop box with coding agents, so you can experiment any time
> without re-running `chezmoi init`. peon's own settings (volume, pack,
> notification style) are deliberately **not** chezmoi-managed — tweak them
> freely, they never show up as drift.

## The ecosystem (three things with confusingly similar names)

| | What it actually is |
|---|---|
| **[OpenPeon](https://openpeon.com/)** | An open **standard** — CESP, the *Coding Event Sound Pack Specification* — **and** the community **registry** (~349 packs). A pack is an `openpeon.json` manifest plus audio files, published on GitHub. |
| **[peon-ping](https://github.com/PeonPing/peon-ping)** | One **player/client** that implements CESP (MIT). Installs hook adapters into agents, downloads packs from the registry, plays them. Other CESP players exist (e.g. Claudette). |
| **[game-sounds](https://github.com/Citedy/game-sounds)** | Unrelated to CESP — a self-contained Claude Code plugin with 63 bundled packs. Not used here. |

Analogy: OpenPeon is the format + index, peon-ping is the client. The name
"peon" comes from the Warcraft III worker ("Work complete!").

The default pack here is **[`sc2_scv`](https://openpeon.com/packs/sc2_scv)** —
StarCraft II Terran **SCV** (Space Construction Vehicle), 44 lines across all
7 CESP categories. Its `task.complete` line is **"Job's finished!"**.

## The four tiers

| `agentSounds` | Wires | You get |
|---|---|---|
| `none` | nothing | silence |
| `notify` *(default)* | `notify.sh` → apprise → `terminal-notifier` | macOS banner |
| `peon` | peon-ping's 9 hook events | SCV voice + peon's own overlay banner |
| `both` | both of the above | banner + voice + peon overlay (two banners — see below) |

Desktop profiles only; `ubuntu_server` / `centos_server` bake `none` (no audio
device, no notification daemon). The `minimal` bundle forces `none`.

**Two banners at `both`** is expected — apprise draws one and peon draws its
own. If that's too much, don't change the tier; just turn peon's visual off at
runtime: `peon notifications off` (sound keeps playing).

## What chezmoi manages, and what it deliberately doesn't

This split is the whole point of the design.

| Managed by chezmoi | Owned by you at runtime |
|---|---|
| **Which hooks exist** — [`dot_claude/modify_settings.json.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_claude/modify_settings.json.tmpl) | Volume, active pack, notification style, mute state — all in `~/.openpeon/config.json` |
| Binary install + first-run pack seed (ansible `coding_agents` role) | Everything reachable via the `peon` CLI |

`~/.openpeon/` is **never** added to the chezmoi source tree. So this is safe
and produces **zero** `chezmoi diff`:

```sh
peon volume 0.3
peon packs use --install glados     # switch away from SCV entirely
peon notifications standard         # plain system notification instead of overlay
peon toggle                         # mute/unmute
peon preview task.complete          # hear the current pack's "done" line
peon packs list --registry          # browse all ~349 packs
```

The ansible seed task is `creates:`-guarded on `~/.openpeon/config.json`, so it
runs **once** on a fresh box and never again — a pack you switch to later
sticks forever.

## Why we never run `peon-ping-setup`

`brew install peon-ping` gives you the binary. `peon-ping-setup` is a separate
step that writes hook entries into `~/.claude/settings.json`. We do the wiring
ourselves and never run setup — the same rule this repo already has for
workmux's `wm setup` (see [AGENTS.md](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md)).

The reason is **not** conflict avoidance. The hook merger is *additive* and
would happily preserve installer-written entries (that's how CodeIsland,
workmux and herdr hooks coexist today). The reasons are:

- **Reproducibility** — an installer-written hook exists only on the box where
  you remembered to run it. Declaring it means every machine gets it from
  `chezmoi apply`.
- **Gating** — the installer has no idea about `agentSounds` or your profile.
- **Blast radius** — `peon-ping-setup` honours `$XDG_CONFIG_HOME` and so
  escapes a faked `$HOME`; it will write into your real `~/.config/opencode/`
  even when you think you've sandboxed it. See
  [`pitfalls/peon-ping-setup-escapes-home.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/peon-ping-setup-escapes-home.md).

The `peon` CLI itself is fully standalone — it creates its own tool-agnostic
root at `~/.openpeon` (packs + config) and needs none of the
`~/.claude/hooks/peon-ping/` tree the installer would build. `libexec/peon.sh`
finds packs there via its packs-anchored fallback.

## Per-agent coverage — two mechanisms, on purpose

| Agent | How | Why |
|---|---|---|
| **Claude Code** | Hook entries in the hook-aware merger | It's a Pattern B "mixed file" — see [agent-overlays.md](agent-overlays.md) |
| **OpenCode** | Ansible symlinks the plugin from peon-ping's `libexec` | OpenCode uses plugins, not hooks. Upstream ships it as a symlink, so linking (not vendoring a copy) keeps it current across upgrades |
| **Codex** | peon-ping's own adapter | `~/.codex/hooks.json` is an always-ignored CodeIsland sidecar |
| **Cursor** | peon-ping's own adapter | `~/.cursor/hooks.json`, same |

Codex/Cursor hook files are *deliberately unmanaged* by chezmoi
([`.chezmoiignore.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoiignore.tmpl)),
so peon-ping's adapter writing them conflicts with nothing.

## The one place we subtract

The merger's rule is "never remove a hook entry" — that's what lets foreign
tools coexist. There is exactly one exception: entries **we** declare are
pruned when the current tier disables them.

Without it `agentSounds` would be a one-way ratchet — switching `notify` →
`none` would leave the already-installed `notify.sh` hook wired forever, so
`none` wouldn't actually silence a machine that previously had sound. The prune
list is built only from our own command fingerprints, so CodeIsland / workmux /
herdr entries can never be touched regardless of tier.

## Verify

```sh
peon status                     # active pack, volume, mute state
peon preview task.complete      # should say "Job's finished!"
jq '.hooks | keys' ~/.claude/settings.json
peon volume 0.4 && chezmoi diff # MUST be empty — proves config isn't managed
```

Per-tier hook wiring is covered by `tests/unit/agent_overlays.bats`
(`agentSounds tiers gate…`, `peon tier keeps its hook guarded…`, `lowering the
tier prunes OUR entries…`).

## Changing tier later

`agentSounds` is a `promptChoiceOnce` — it's only asked when absent from your
chezmoi config. To change it on an existing machine:

```sh
just reconfigure --set agentSounds=peon --yes
chezmoi apply
```

> **Legacy-profile gotcha.** A machine whose config still carries the retired
> `macos_intel` profile does not match the desktop gate, so `agentSounds` bakes
> to `none` (as do all other desktop-gated prompts). `just reconfigure` detects
> the retired value and re-picks the profile — run it before debugging anything
> else if a desktop Mac mysteriously gets `none`.

## See also

- [agent-overlays.md](agent-overlays.md) — the hook-aware merger and the
  CodeIsland coexistence design
- [workmux.md](workmux.md) — the `wm setup` rule this mirrors
- [tool-managers.md](../this_repo/tool-managers.md) — how peon-ping is installed
