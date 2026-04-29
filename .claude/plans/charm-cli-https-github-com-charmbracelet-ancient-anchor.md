# Add Charm CLI tools (gum, vhs, freeze) + evaluate mods/crush

## Context

Repo already uses `charmbracelet/glow` (markdown renderer, installed via
`dot_ansible/roles/devtools/tasks/main.yml`). User wants to add more
Charm tools they'd actually use day-to-day. After surveying ChatGPT's
recommendations against the repo's existing infrastructure:

- **gum** — clear, immediate value: 4 concrete spots in this repo's own
  scripts could use it (`tmux menu.sh` tier system, `menu-theme.sh`,
  `scripts/import_ssh_to_bw.sh` `read`-prompts, `scripts/upgrade_tools.sh`
  no-interactive-mode). User chose "install only, no refactor" — so we
  install now, refactor later when concrete need shows up.
- **vhs / freeze** — speculative but cheap. Currently zero `.tape` files
  and zero GIFs in `docs/`. Installing unblocks future demo recording for
  flows like `fleet-apply`, `sesh + tmux`, `tv agent-panes`.
- **mods / crush** — separately evaluated below; not auto-installed.

Goal: install the three CLIs cross-platform via the repo's existing
patterns (macOS Homebrew list + Linux GitHub-release fallback), document
them, and update all the cross-file mirrors `CLAUDE.md` requires.

---

## What to install

### Tier 1 — install in this PR

| Tool | Purpose | macOS | Linux |
|---|---|---|---|
| `gum` | Shell-script-friendly prompts (`gum choose`, `input`, `confirm`, `spin`, `filter`, `format`, `style`) | brew | GitHub release → `~/.local/bin/gum` |
| `vhs` | Record terminal sessions to GIF/MP4 from `.tape` script | brew | GitHub release → `~/.local/bin/vhs` |
| `freeze` | Code / terminal-output → static image (PNG/SVG) | brew | GitHub release → `~/.local/bin/freeze` |

### Tier 2 — out of scope (decision documented, not installed)

- **`mods`** — CLI LLM client. Skip: repo already has `aicapture` /
  `aisuggest` ecosystem (`dot_config/zsh/tools/04_ai_capture.zsh`,
  `05_aisuggest.zsh`) wrapping Claude / OpenCode / Codex / Cursor with
  per-agent model overrides (`AICAP_*_MODEL` env vars). `mods` would
  duplicate functionality without integrating with the existing
  agent-detection chain. Will add a one-paragraph note to
  `docs/tools/aicapture.md` explaining the deliberate non-choice.
- **`crush`** — Charm's agentic coding CLI. Skip: repo already manages
  4 coding-agent CLI overlays (Claude / OpenCode / Codex / Cursor) via
  `modify_` chezmoi prefix in `dot_claude/`, `dot_config/opencode/`,
  `dot_codex/`, `dot_cursor/`. The cost-of-ownership of each agent
  overlay is non-trivial (hook-aware mergers, TOML round-tripping). If
  user later wants to try `crush`, the existing pattern at
  `docs/tools/agent-overlays.md` plus
  `dot_ansible/roles/coding_agents/tasks/main.yml` is the documented
  add-a-5th-agent path.

### Explicitly NOT in scope

- `bubble-tea`, `bubbles`, `lip-gloss`, `glamour`, `huh` — Go libraries,
  not CLIs. Not relevant for a dotfiles repo (would only matter if
  authoring Go TUI apps).
- `wish`, `soft-serve`, `skate` — server-side / SSH-app tools. No
  current need; user not running self-hosted Git or KV store.
- `pop` (email), `melt` (mnemonic backup) — niche, not requested.

---

## Files to modify

### 1. Ansible role — `dot_ansible/roles/devtools/tasks/main.yml`

**Module-level header comment** (line 3): add `gum, vhs, freeze` to the
end of the tool list.

**macOS Homebrew list** (lines 17–52): add `- gum`, `- vhs`, `- freeze`
to the `community.general.homebrew` `name:` list (alphabetically: `gum`
between `grc` and `htop`; `vhs` after `television`; `freeze` after
`eza`).

**Linux GitHub-release blocks** — append three new blocks following the
exact `glow` pattern at lines 1202–1310. For each tool, copy the
13-task block and rename. Per-tool details:

| Tool | Repo | Asset name template | Binary inside |
|---|---|---|---|
| `gum` | `charmbracelet/gum` | `gum_<ver>_Linux_<arch>.tar.gz` | `gum` |
| `vhs` | `charmbracelet/vhs` | `vhs_<ver>_Linux_<arch>.tar.gz` | `vhs` |
| `freeze` | `charmbracelet/freeze` | `freeze_<ver>_Linux_<arch>.tar.gz` | `freeze` |

Architecture mapping is identical to `glow` (x86_64/arm64/arm). All
three follow `charmbracelet`'s standard release naming, so the glow
block's URL template `…/{{ tag }}/<tool>_{{ ver }}_Linux_{{ arch }}.tar.gz`
works as-is.

**Important**: keep `rescue:` block on each (network-timeout
tolerance) — see `glow` lines 1304–1310.

**Note on `vhs` runtime deps**: `vhs` requires `ttyd` and `ffmpeg` at
runtime to actually record. On Linux, both are usually missing. The
ansible block will install the binary; runtime deps documented in
`docs/tools/vhs.md` as a "before first use" step. Don't auto-install
`ttyd`/`ffmpeg` — they're heavy and `vhs` is opt-in.

### 2. Tool docs — three new pages under `docs/tools/`

Create:

- `docs/tools/gum.md` (~200 lines) — `gum choose / input / confirm /
  spin / filter / format / style` with concrete examples reusing patterns
  from this repo's own scripts (so the doc doubles as a "here's where
  it would slot in" hint when refactor time comes). Cross-link from
  `docs/tools/tmux/keybindings.md` (mention as alternative to
  `display-menu` for ≥14-row menus).
- `docs/tools/vhs.md` (~150 lines) — install, runtime deps
  (ttyd/ffmpeg), `.tape` script syntax, recording a demo. Note that
  the repo doesn't yet have any `.tape` files; section "Where to put
  tapes" suggests `docs/_demos/*.tape` if/when used.
- `docs/tools/freeze.md` (~120 lines) — `freeze main.py -o code.png`,
  flags for theme/font, integration with `bat` for syntax highlighting.

Each page's structure follows the established template from
`docs/tools/fzf.md` / `docs/tools/direnv.md`: title + upstream link, why
in this repo, install verification, examples, troubleshooting.

**Optional page** — `docs/tools/glow.md` (~80 lines): repo uses glow but
has no docs page. Could be a small bonus addition since we're touching
this surface anyway. **Decision**: include it, since the per-page cost is
low and `mkdocs.yml` will need a new section anyway. Cross-link from
`docs/tools/web-reader.md` (which already mentions glow at line 11).

### 3. zh-TW translations

Per the existing pattern (every English page has a `.zh-TW.md` sibling —
visible in the `ls docs/tools/` output: 39 pages × 2 languages), each
new page needs a `.zh-TW.md` translation. Follow the "preserve English
originals for proper nouns / commands / file paths" rule from the
`mkdocs-site-bootstrap` skill that bootstrapped this repo's i18n.

### 4. `mkdocs.yml` nav

Insert under the existing `Tools → Shell & terminal` block (line ~213):

```yaml
- Shell & terminal:
    - Ghostty: tools/ghostty.md
    - Warp: tools/warp.md
    - Starship: tools/starship.md
    - Clipboard: tools/clipboard.md
    - XDG: tools/xdg.md
    - Fzf: tools/fzf.md
    - Television (tv): tools/tv.md
    - TV vs fzf: tools/tv-vs-fzf.md
    - Glow (markdown reader): tools/glow.md       # NEW
    - Gum (shell prompts): tools/gum.md           # NEW
    - VHS (terminal demo recorder): tools/vhs.md  # NEW
    - Freeze (code → image): tools/freeze.md      # NEW
```

Order: existing alpha-ish-but-narrative ordering keeps fzf/tv together;
glow/gum/vhs/freeze form a natural Charm cluster at the end.

### 5. `README.md`

Update line 239 — the "Dev tools" list under "What You Get". Add `gum,
vhs, freeze` to the comma-separated list (after `glow`, since they're
the same upstream).

Add nothing else to README — the tools don't appear in macOS-only
playbooks, ansible role headers, or the "Quick Setup" flow.

### 6. `CLAUDE.md` — no change required

The cross-file maintenance rules already cover what we're doing
(devtools role → README.md, new docs page → mkdocs.yml). Nothing here
graduates to a hard invariant.

### 7. Cross-link from `docs/tools/aicapture.md`

Add a one-paragraph "Why not Charm `mods`?" note (≤6 lines) explaining
the deliberate skip. Lives near the top of the page where the
multi-agent chain is described. Same for `crush` if there's a natural
spot in `docs/tools/agent-overlays.md`.

---

## Critical files referenced (existing, do not modify)

- `dot_ansible/roles/devtools/tasks/main.yml:1202-1310` — glow install
  block, copy 3× for the new tools.
- `dot_ansible/roles/devtools/tasks/main.yml:17-52` — macOS Homebrew
  list, add 3 entries.
- `dot_ansible/roles/devtools/tasks/main.yml:3` — module header tool list.
- `mkdocs.yml:213-220` — Shell & terminal nav block.
- `README.md:239` — Dev tools list.
- `docs/tools/fzf.md` and `docs/tools/direnv.md` — page-structure
  templates for the new tool docs.
- `docs/tools/aicapture.md` — landing point for the "mods skipped" note.
- `docs/tools/agent-overlays.md` — landing point for the "crush
  skipped" note.

## Critical files referenced (showcasing future gum opportunities — NOT modified in this PR)

User explicitly chose "install only, no refactor". Documented here so
that future-you (or future-Claude) knows where to look:

- `dot_config/tmux/executable_menu.sh:23-70` — tier system fights tmux's
  silent-fail-when-too-tall bug; `gum choose --height N` could replace
  it cleanly. (Pitfall:
  `pitfalls/tmux-display-menu-silent-fail.md` is the relevant warning.)
- `dot_config/tmux/executable_menu-theme.sh` — 2-row menu, trivial
  `gum choose` substitute.
- `scripts/import_ssh_to_bw.sh:182-258` — `read -r choice` /
  `read -r overwrite` flow is ideal for `gum choose --no-limit` +
  `gum confirm`.
- `scripts/upgrade_tools.sh:84-177` — when no args given, currently
  defaults to `all`; could optionally drop into `gum choose --no-limit`
  for category multi-select.

---

## Verification

After implementation, run all of these and confirm clean output:

```bash
# 1. Templating sanity (run from repo root)
chezmoi diff | head -50              # should show new ansible task additions only

# 2. MkDocs strict build catches dangling links / nav typos
uv run mkdocs build --strict

# 3. Apply on the local machine and verify binaries land
chezmoi apply
which gum vhs freeze glow            # all 4 should resolve
gum --version && vhs --version && freeze --version && glow --version

# 4. Smoke-test gum interactively
gum choose --header "Smoke test" "hello" "world"
echo "name: $(gum input --placeholder 'demo')"

# 5. Smoke-test freeze (no runtime deps needed)
echo 'print("hello")' > /tmp/hello.py
freeze /tmp/hello.py -o /tmp/hello.png && file /tmp/hello.png

# 6. Smoke-test vhs only if ttyd+ffmpeg available
command -v ttyd && command -v ffmpeg && {
  cat <<'TAPE' > /tmp/demo.tape
Output /tmp/demo.gif
Set FontSize 18
Type "echo hello vhs"
Enter
Sleep 1s
TAPE
  vhs /tmp/demo.tape && file /tmp/demo.gif
}

# 7. Linux: verify GitHub-release path actually picks the right asset
# Run on a Linux host:
ls -la ~/.local/bin/{gum,vhs,freeze}

# 8. Upgrade path inherits for free (per-category brew/etc. handles bumps)
just upgrade brew  # macOS — gum/vhs/freeze move with brew upgrade
```

A successful run leaves three new binaries on `$PATH`, four new doc
pages live on the MkDocs site, and the `mkdocs --strict` build green.
