# Plan: Terminal Office-document viewing (doxx + markitdown + LibreOffice + `view-office` + yazi preview)

## Context

There is currently **no way to view Microsoft Office documents from the terminal** in this repo. Research (see the SpecStory history for this session) found the best-practice landscape is *per-format + two-mode* (quick glance vs. interactive read); no single tool covers everything. This machine already has `pandoc`, `visidata` (`vd`), `glow`, `bat`, `yazi`, `tv`, but is missing a real terminal-native Word viewer, an Office→markdown converter, and any integration wiring.

**Goal:** add the missing tools and a single dispatcher CLI so that (a) `view-office FILE` opens the right interactive viewer per extension, (b) `view-office --preview` emits ANSI/markdown to stdout, and (c) yazi previews Office files inline by calling that same dispatcher. Legacy binary formats (`.doc/.xls/.ppt`) are covered via LibreOffice headless conversion.

**User-confirmed choices** (this session):
1. Yazi previewer → **introduce the `ya pkg` plugin manager** (install `piper.yazi` properly; enables future plugins). This is the repo's first yazi-plugin mechanism.
2. Legacy formats → **add LibreOffice** (`soffice --headless --convert-to`) as a fallback dependency.
3. `view-office` scope → **smart dispatcher + `--preview` mode** (single source of truth that yazi/tv/fzf all call).

**Verified facts** (web + exploration): `doxx FILE` = interactive TUI; `doxx FILE --export ansi|markdown|text` (+ `-w COLS`) = stdout. `ya pkg add yazi-rs/plugins:piper` / `ya pkg install` / `ya pkg upgrade`; lockfile `~/.config/yazi/package.toml` (`[[plugin.deps]]` use/rev/hash); plugins land in `~/.config/yazi/plugins/`. piper previewer: `[[plugin.prepend_previewers]] url="*.docx" run='piper -- <cmd>'`, shell sees `$1` (path) `$w` (width) `$h` (height) `$t` (theme). markitdown = `uv tool install markitdown`, binary `markitdown`, converts docx/xlsx/**pptx**→markdown (pandoc canNOT read pptx/xlsx — do not use it for those).

---

## Work items

### 1. Install `doxx` (Rust binary) — `dot_ansible/roles/devtools/tasks/main.yml`

Mirror the **workmux** treatment (tarball mechanics) but with **herdr's arch mapping** (asset is `doxx-Linux-<uname -m>.tar.gz` → `x86_64`/`aarch64`, not `amd64`/`arm64`).
- **macOS (3 parts):** new `community.general.homebrew_tap` task `name: bgreenwell/tap` (copy the `raine/workmux` tap task ~L15-23); add `bgreenwell/tap` to the tap-trust `loop:` (~L36-38); add `- doxx` to the macOS `homebrew` install `name:` list (~L78 area).
- **Linux (Debian):** clone the whole workmux release block (~L3242-3383): `doxx --version` idempotency probe (with `PATH` env prepending `~/.local/bin`) → `block:` guarded on `rc != 0` + arch → GitHub `uri` latest release → arch `set_fact` mapping to `x86_64`/`aarch64` (herdr style ~L4315-4322) → `selectattr('name','equalto','doxx-Linux-'~arch~'.tar.gz')` → `get_url` → `ansible.builtin.unarchive` (Linux-only, GNU tar — safe per repo memory) → `find` binary → `copy` to `~/.local/bin/doxx` `mode:0755` → cleanup, all in `rescue:`. No `wm`-style symlink needed.
- Append `doxx` to the top-of-file `# Tools:` comment (L3).

### 2. Install `markitdown` (uv tool) — `dot_ansible/roles/python_uv_tools/defaults/main.yml`

Append a 2-line entry to `python_uv_tools:` (same shape as `apprise`/`tmuxp`):
```yaml
  - name: markitdown
    binary: markitdown
```
No `with`/`python`/`needs_modern_gcc`/`extra_binaries`. `tasks/main.yml` consumes it automatically (no change there).

### 3. Install LibreOffice — `dot_ansible/roles/devtools/tasks/main.yml`

- **macOS:** `community.general.homebrew_cask` task `name: libreoffice` (cask, not formula — installs `/Applications/LibreOffice.app`; `soffice` lives at `…/Contents/MacOS/soffice`, NOT on PATH — `view-office` handles that path). Model on an existing cask task in the role.
- **Linux (Debian):** `ansible.builtin.apt` `name: libreoffice-nogui` (or `libreoffice` if `-nogui` unavailable) `state: present`, `become: true`, `tags: [sudo]` — mirror the pandoc apt task (~L2755). Add a comment noting it's a heavy (~hundreds of MB) fallback for legacy `.doc/.xls/.ppt` only.
- Append `libreoffice` to the L3 `# Tools:` comment.

### 4. `view-office` dispatcher CLI — `dot_dotfiles/bin/executable_view-office`

**Language: POSIX/bash, NOT the Python uv-self-boot pattern.** Rationale: it sits on yazi's preview hot-path (invoked on every hover); `uv run --script` adds ~100-200ms startup, bash ~5ms. Deliberate divergence from `executable_pqsum`/`executable_yth` — document the reason in a header comment.

Interface: `view-office [--preview] [--width N] FILE`
- Resolve lowercase extension. `--width` defaults to `${COLUMNS:-100}`.
- Helper `have(){ command -v "$1" >/dev/null 2>&1; }`; `soffice_bin()` = first of `soffice`/`libreoffice` on PATH, else macOS app path `/Applications/LibreOffice.app/Contents/MacOS/soffice`. Missing-tool → `view-office: <tool> not found — install via <role>` on stderr, exit 2.

| ext | interactive (default) | `--preview` (stdout) |
|---|---|---|
| `.docx` | `doxx "$f"` | `doxx --export ansi -w "$width" "$f"` |
| `.xlsx` | `vd "$f"` (visidata) | `markitdown "$f" \| glow -w "$width" -` |
| `.pptx` | `markitdown "$f" \| glow -p` | `markitdown "$f" \| glow -w "$width" -` |
| `.doc/.xls/.ppt/.odt/.ods/.odp/.rtf` | `soffice` convert → OOXML twin in `$(mktemp -d)` → **recurse** `view-office "$twin"` | same, with `--preview` |

Legacy conversion: `soffice --headless --convert-to <docx\|xlsx\|pptx> --outdir "$tmp" "$f"` then re-dispatch. Unknown ext → error + usage. `--help`/`-h` fast path prints usage.

### 5. Yazi Office previewer via `ya pkg` + piper

- **New managed lockfile** `dot_config/yazi/package.toml`: generate by running `ya pkg add yazi-rs/plugins:piper` locally, then `chezmoi add ~/.config/yazi/package.toml`. Contains the pinned `[[plugin.deps]] use="yazi-rs/plugins:piper"` rev/hash.
- **New run-script** `.chezmoiscripts/global/run_onchange_after_46_yazi_plugins.sh.tmpl` (pick a free NN; 40=skills, 50=completions, so 46 is free). Guards on `command -v ya` and `command -v yazi` (graceful skip on fresh boxes), then `ya pkg install`. Embed `# package.toml hash: {{ include "dot_config/yazi/package.toml" | sha256sum }}` in a comment so it re-runs only when the lockfile changes. `ya pkg install` reads (does not rewrite) package.toml → no chezmoi ping-pong; fetched plugins under `~/.config/yazi/plugins/` are unmanaged and left alone.
- **`dot_config/yazi/yazi.toml`** — add a `[plugin]` section (first previewer customization in this file) with one `prepend_previewers` per extension:
```toml
[[plugin.prepend_previewers]]
url = "*.docx"
run = 'piper -- view-office --preview --width "$w" "$1"'
# repeat for *.xlsx *.pptx *.doc *.xls *.ppt *.odt *.ods *.odp *.rtf
```

### 6. Completions — Strategy B hand-written pair (next free NN = **55**)

Copy the minimal `wake` pair. `view-office` takes `[--preview] [--width N] FILE`:
- `dot_config/zsh/tools/55_view_office_completion.zsh` — `(( $+commands[view-office] )) || return 0`; `_arguments` with `--preview`, `--width`, `-h/--help`, `1:file:_files -g '*.docx *.xlsx *.pptx *.doc *.xls *.ppt *.odt *.ods *.odp *.rtf'`; `compdef _view_office view-office`.
- `dot_config/bash/55_view_office_completion.bash` — mirror; `command -v view-office`; `_filedir`; header cross-refs the zsh twin + §F.

### 7. Docs (same-commit mirrors per CLAUDE.md)

- **New page `docs/tools/office-viewers.md`** — covers doxx / markitdown / LibreOffice fallback / `view-office` dispatch table / yazi `ya pkg`+piper integration; cross-link existing `pandoc`, `visidata` (aliases §Data Viewers), `web-reader.md`.
- **`mkdocs.yml`** — nav entry `- Office viewers (doxx / markitdown): tools/office-viewers.md` under `Productivity:` (next to `Web reader`, ~L331-334); add zh-TW twin in the `plugins.i18n` title block (~L146).
- **`docs/this_repo/tool-managers.md`** — A–Z rows for **doxx** (`| **doxx** | brew tap `bgreenwell/tap` | GitHub release `.tar.gz` | devtools |`, alpha ~after `doggo`), **markitdown** (`| **markitdown** | uv tool | uv tool | python_uv_tools |`, ~after `marimo`), **libreoffice** (`brew cask | apt | devtools`). Add `bgreenwell/tap` to the Tap inventory (~L209-212). Add `markitdown` row to the § 5 uv Tool-inventory table (~L468-485). **New mechanism → also add a § subsection "yazi plugins (`ya pkg`)"** documenting package.toml + `ya pkg install` (via the run-script) + `ya pkg upgrade`, and a branch in the § Decision tree.
- **`README.md`** — new bullet under `### Tools (via ansible)` (~L288) e.g. "Office/document viewing: doxx, markitdown, LibreOffice headless, `view-office` dispatcher"; append `markitdown` to the uv flat list (~L322) and `doxx`, `libreoffice` to the devtools flat list (~L316).
- **`dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`** — one bullet in the in-house-CLI list (~L114-124): `` - **`view-office`** — open/preview Office docs (.docx/.xlsx/.pptx + legacy) in the terminal. See `docs/tools/office-viewers.md`. `` (doxx/markitdown are third-party, not in-house — no bullet.)
- **`docs/zsh/zsh-completions.md`** — add a Section F table row for `view-office` (Strategy B).
- **`CLAUDE.md`** — one new cross-file-maintenance row (keep concise; headroom rule <30k). Surface: *Office viewing*. Mirrors: `executable_view-office` ↔ completions `55_*` ↔ SKILL.md bullet ↔ `docs/tools/office-viewers.md`; **and** the piper contract — `dot_config/yazi/yazi.toml` `run='piper -- view-office --preview --width "$w" "$1"'` ↔ `view-office`'s `--preview`/`--width` interface ↔ `dot_config/yazi/package.toml` (piper dep) ↔ `run_onchange_after_46_yazi_plugins.sh.tmpl` (change one → change all).

### 8. Upgrades (install-vs-upgrade split) — `scripts/upgrade_tools.sh` + `docs/this_repo/upgrades.md`

`ya pkg` is a **new upgrade category**: add a `yazi-plugins` case running `ya pkg upgrade` (guarded on `ya`) to `scripts/upgrade_tools.sh`, wire a `just upgrade-yazi-plugins` recipe, and document it in `docs/this_repo/upgrades.md` → "Adding a new category". doxx (brew/tarball) follows workmux's existing upgrade story; markitdown (uv) is picked up by the generic uv upgrade; libreoffice by brew/apt — no new work for those.

---

## Verification (end-to-end, not just syntax)

1. **Render/lint:** `chezmoi execute-template < dot_config/yazi/yazi.toml`? (it's not a template) — instead `chezmoi cat ~/.config/yazi/yazi.toml` after apply; `chezmoi diff` to preview all changes. Ansible: `ansible-playbook --syntax-check` on the devtools + python_uv_tools plays, then narrow `--tags` run or container smoke per the repo's "validate with the app" rule.
2. **Tools install:** run the devtools + python_uv_tools roles (or `just` equivalents); confirm `doxx --version`, `markitdown --version`, `soffice --version` (or macOS app path), `command -v view-office`.
3. **Sample files:** generate tiny fixtures via uv, e.g. `uv run --with python-docx python -c "..."` (docx), `--with openpyxl` (xlsx), `--with python-pptx` (pptx); make a legacy `.doc` with `soffice --headless --convert-to doc sample.docx`.
4. **`view-office` both modes:** for each of docx/xlsx/pptx run `view-office FILE` (interactive TUI opens: doxx / vd / glow-pager) and `view-office --preview --width 100 FILE` (ANSI/markdown to stdout). Then the legacy `.doc` through both paths (confirms soffice convert→recurse). Confirm missing-tool hints by temporarily shadowing PATH.
5. **Yazi preview:** `ya pkg install` (or full `chezmoi apply` to fire the run-script), launch `yazi`, hover each Office file, confirm inline preview renders (this exercises yazi.toml → piper → view-office → doxx/markitdown). Manual — yazi needs a TTY (see repo memory on TTY-less tools).
6. **Completions:** `source` each `55_*` file in a fresh zsh/bash; `view-office <Tab>` completes flags and Office-extension files.
7. **Docs:** `uv run mkdocs build --strict` passes (accounting for the known baseline warnings per repo memory — stash-rebuild to confirm no new regressions).

## Out of scope
- PDF (yazi already previews it), Markdown files, and Google-Docs/online formats.
- `.numbers/.pages/.key` (Apple iWork) — note as a future item if raised.
