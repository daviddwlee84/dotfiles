# Agent completion sounds — `agentSounds` prompt + self-managed peon-ping

## Context

Today every machine gets the same unconditional completion feedback: the `Stop`
hook in `dot_claude/modify_settings.json` runs `~/.claude/hooks/notify.sh` →
`apprise --tag desktop` → `macosx://` → `terminal-notifier` → a macOS banner.
There is no prompt to turn it off, and no audio option.

We want tiered feedback chosen at `chezmoi init` time, plus a docs page
explaining the ecosystem (this is a crowded, confusingly-named space).

### OpenPeon vs peon-ping (the question that started this)

They are **not competitors** — they are spec/registry vs client:

| | What it is |
|---|---|
| **OpenPeon** | The open **standard** (CESP — Coding Event Sound Pack Specification) *and* the community **registry** (~349 packs). A pack = `openpeon.json` manifest + audio files, published on GitHub. |
| **peon-ping** | One **player/client** implementing CESP (MIT). Installs hook adapters into agents, downloads packs from the registry, plays them. Other CESP players exist (e.g. Claudette). |

Rough analogy: OpenPeon is the format + index; peon-ping is the CLI that
consumes it. [`Citedy/game-sounds`](https://github.com/Citedy/game-sounds) is a
third thing again — a self-contained Claude Code plugin with 63 bundled packs,
**not** CESP, and its StarCraft pack does not advertise SCV worker lines.

The wanted sound is **StarCraft II Terran SCV** ("SCV" — Space Construction
Vehicle; "Human" = Terran). Pack [`sc2_scv`](https://openpeon.com/packs/sc2_scv)
— 44 lines, all 7 CESP categories, and `task.complete` → **"Job's finished!"**.

### Correction to an earlier claim in this session

I previously warned that letting peon-ping's installer write hooks would
ping-pong with `chezmoi apply`. **That was wrong.** The merger in
`dot_claude/modify_settings.json` is deliberately *additive*: it appends only
overlay entries whose `.hooks[0].command` isn't already present and preserves
every live entry verbatim. That is why CodeIsland, workmux, and herdr hooks all
survive today (the live `SessionStart` herdr hook is in no overlay).

So the reason to self-manage is **not** conflict avoidance — it is
**reproducibility and gating**: an installer-written hook exists only on the box
where you remembered to run it, is invisible to the fleet, and ignores the
profile. This mirrors the existing `CLAUDE.md` rule *never run `workmux setup` on
a managed machine*. `peon-ping` gets the same treatment: `brew install` provides
the binary, and we never run `peon-ping-setup`.

## Design decisions

### Four tiers, and they only control hook wiring

`agentSounds` choice prompt, values `none` / `notify` / `peon` / `both`
(default `notify` — today's behavior):

| Value | Wires |
|---|---|
| `none` | nothing — silent |
| `notify` | notify.sh → apprise → macOS banner |
| `peon` | peon-ping hooks → SCV voice + peon's own overlay banner |
| `both` | notify.sh **and** peon-ping (apprise banner + voice + peon overlay) |

Gated `condition=When(profile=_DESKTOP_PROFILES)`, `else_value="none"` — headless
servers have no audio or notification daemon. Same shape as `discordChannel`.
`minimal` bundle forces `"none"`.

`peon` exists as its own tier specifically so peon's overlay UX can be evaluated
on its own; `both` keeps the stacked combination reachable without editing the
overlay later.

### The binary installs independently of the tier

`installCodingAgents && desktop profile` → install the `peon` binary and seed the
`sc2_scv` pack, **whatever the tier is**. So `peon preview task.complete`,
`peon packs list`, etc. are always available to play with. The prompt decides
only whether hooks get wired.

### chezmoi does NOT manage peon's config

This is the load-bearing constraint. `~/.claude/hooks/peon-ping/config.json` is
written at runtime by `peon toggle` / `peon volume` / `peon notifications` /
`peon packs use`. Managing it would mean every knob you turn shows up as chezmoi
drift — exactly what you don't want.

So: **seed once, never touch again.** The ansible task is guarded so it runs only
on a box that has no peon config yet:

```yaml
- name: Seed peon-ping default pack (first run only)
  ansible.builtin.shell: |
    peon packs install sc2_scv && peon packs use sc2_scv
  args:
    creates: "{{ ansible_env.HOME }}/.claude/hooks/peon-ping/config.json"
```

`creates:` matches the repo's install-only philosophy. After that, `peon packs
use <anything>` sticks forever and produces zero chezmoi diff. Nothing under
`~/.claude/hooks/peon-ping/` is added to the chezmoi source tree; add it to
`.chezmoiignore.tmpl` as always-ignore (same treatment as the CodeIsland
sidecars) so a stray `chezmoi add` can't pull it in.

### Agent coverage splits into two mechanisms

| Agent | Mechanism | Why |
|---|---|---|
| Claude Code | Hook entries in the (now templated) hook-aware merger | Pattern B mixed file — merger already exists |
| OpenCode | New chezmoi-managed plugin, sibling of `dot_config/opencode/plugins/workmux-status.ts` | OpenCode uses plugins, not hooks |
| Codex | peon-ping's own adapter | `~/.codex/hooks.json` is an always-ignored CodeIsland sidecar (`.chezmoiignore.tmpl:258`) |
| Cursor | peon-ping's own adapter | `~/.cursor/hooks.json`, same (`:259`) |

Codex/Cursor hook files are *deliberately unmanaged* — the repo's documented
stance (`docs/tools/agent-overlays.md` → "Pattern A — Sidecar files"). Because
chezmoi ignores those paths, peon-ping's adapter writing them conflicts with
nothing. Managing them would mean un-ignoring a CodeIsland-owned file and
building a second merger — strictly worse.

## Implementation

### 1. Prompt (SSOT → generated)

- `scripts/init/dotfiles_init.py`: add `Prompt("agentSounds", "choice", …)` to
  `PROMPTS` (group "Coding agents & AI"),
  `choices=("none","notify","peon","both")`, `default="notify"`,
  `prompt_text="Agent completion feedback (none|notify|peon|both)"`,
  `condition=When(profile=_DESKTOP_PROFILES)`, `else_value="none"`, bilingual
  `comment=`. Add `"agentSounds": "none"` to the `minimal` bundle.
- `just gen-prompts` regenerates `.chezmoi.toml.tmpl` + `Dockerfile`.
  **Never hand-edit the marker regions**; `just gen-prompts -- --check` and the
  `dotfiles-init-gen-check` pre-commit hook fail on drift.
- `README.md`: add the option-table row.

### 2. Claude Code hooks

Rename `dot_claude/modify_settings.json` → `dot_claude/modify_settings.json.tmpl`
(verified: the file contains **zero** `{{`, so templating is safe; several
`modify_*.tmpl` files already exist, e.g. `dot_config/herdr/modify_config.toml.tmpl`).

- notify.sh entries → `{{ if or (eq .agentSounds "notify") (eq .agentSounds "both") }}`
- peon-ping entries → `{{ if or (eq .agentSounds "peon") (eq .agentSounds "both") }}`
- workmux entries stay unconditional.

**Do not trust the README's hook command strings** (the summary I fetched marked
several as "implied"). Derive them empirically first:

```sh
CLAUDE_CONFIG_DIR=/tmp/peon-probe peon-ping-setup     # throwaway root
jq '.hooks' /tmp/peon-probe/settings.json             # lift exact entries
```

### 3. OpenCode plugin

New `dot_config/opencode/plugins/peon-ping.ts`, modelled on `workmux-status.ts`
(same header conventions: source path, upstream URL, refresh strategy). Gate
deployment on the tier via `.chezmoiignore.tmpl`. Check whether
`dot_config/opencode/modify_package.json` needs a dep entry.

### 4. Install

- `dot_ansible/roles/coding_agents/`: gated on `installCodingAgents` + desktop
  profile (**not** on the tier). macOS → `homebrew_tap: PeonPing/tap` +
  `brew install peon-ping`; Linux → `curl -fsSL …/install.sh | bash` (matches the
  existing Claude Code / OpenCode / Cursor / Antigravity curl-installer tasks in
  that role). **Never run `peon-ping-setup`** — binary only. Then the
  `creates:`-guarded first-run pack seed above.
- `dot_ansible/roles/devtools/tasks/main.yml`: add `PeonPing/tap` to the
  `devtools_tap_info` trust loop (lines 33–41) — the in-file comment requires
  this for every new third-party tap (Homebrew 6 formula-trust gate; see
  `pitfalls/homebrew-6-refuses-untrusted-tap-formula.md`).

### 5. Docs

- New `docs/tools/agent-sounds.md` + `.zh-TW.md`: ecosystem map (CESP / OpenPeon
  / peon-ping / game-sounds), the four tiers and what each wires, why we don't
  run `peon-ping-setup`, why peon's config is deliberately unmanaged and which
  `peon` commands are yours to use freely, the Codex/Cursor sidecar split, and
  how to verify.
- `mkdocs.yml`: nav entry under "Editor & agents", next to `tools/agent-overlays.md`.
- `docs/this_repo/tool-managers.md` + `.zh-TW`: A–Z row for `peon-ping`
  (required by `CLAUDE.md` for any newly installed tool).
- `docs/tools/agent-overlays.md`: cross-link from the notify.sh discussion.

## Verification

1. `just gen-prompts -- --check` → clean.
2. Render the overlay at each tier and confirm the right hook set:
   ```sh
   for v in none notify peon both; do
     echo "== $v =="
     chezmoi execute-template --init \
       --promptChoice "Agent completion feedback (none|notify|peon|both)=$v" \
       < dot_claude/modify_settings.json.tmpl | jq -r '.hooks | keys[]?'
   done
   ```
3. Run the rendered merger against a fixture containing foreign (CodeIsland /
   herdr) entries and confirm they survive — the repo already has bats coverage
   (`docs/tools/agent-overlays.md` names the cases); add an `agentSounds` case.
4. `chezmoi apply` on this Mac at `peon`, then end-to-end: `peon packs list`
   shows `sc2_scv`; `peon preview task.complete` plays "Job's finished!"; finish
   a real Claude turn and confirm voice + exactly one banner.
5. **Config-cleanliness check** (the point of this design): run
   `peon volume 0.5 && peon notifications standard`, then `chezmoi diff` → must
   be empty, and a subsequent `chezmoi apply` must not revert either setting.
6. `uv run mkdocs build --strict` → no *new* warnings (baseline is 12 pre-existing
   llmstxt/nav warnings).
7. Confirm `~/.claude/settings.json` still contains the herdr `SessionStart` and
   any CodeIsland entries after apply — proves the additive merge is intact.

## Open item

The apprise test I fired earlier (exit 0) — you never said whether you actually
*heard* a sound. If it was silent, the `notify` tier is visual-only today
(macOS per-app notification sound for `terminal-notifier` is off), which makes
the `peon` tier the only one that produces audio. Doesn't change the plan, but
worth knowing when picking your default.
