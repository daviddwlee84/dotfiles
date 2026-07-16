# Maximize Yazi Preview Coverage (images / PDF / video / archives / SVG / EPUB / dmg)

## Context

Yazi today only previews tabular/office files (duckdb.yazi + `view-office`). Everything else
falls through to yazi's **built-in** previewers, which shell out to external binaries at
runtime — and most of those binaries aren't installed by this repo, so on hover the user sees:

- **`failed to spawn chafa`** on png/pdf/mp4/HEIC — yazi's built-ins rasterize each to an image,
  then display it via the adapter it auto-selects. With no native graphics protocol available
  (e.g. inside tmux, or a non-graphics terminal) that adapter is **chafa** (yazi's documented
  "last fallback resort"), which isn't installed. One missing tool breaks *all* image-derived
  previews at the shared display step.
- **`failed to start either 7zz or 7z. Do you have 7-zip installed?`** — no 7-Zip → no archive
  or dmg preview.
- **EPUB / dmg → bare file-type classification** — their mimes (`application/epub+zip`,
  `application/x-apple-diskimage`) aren't in yazi's built-in archive set.

**Root cause is tool-install, not config** — nothing in `dot_config/yazi/` names these tools
(confirmed by full grep). Fix = install yazi's documented optional deps across macOS + Linux,
plus two tiny `piper` rules for the two container formats yazi ignores by default.

Coverage matrix (verified against yazi upstream docs + this host, Intel mac, yazi 26.1.22):

| Preview | Needs | Repo status |
|---|---|---|
| png/jpg/webp/gif  **+ the display step of every image-derived preview** | **chafa** | missing → baseline adds |
| PDF | poppler (`pdftoppm`) + chafa | poppler unmanaged → baseline adds |
| archives (zip/tar/7z/rar/gz…) **+ dmg** | **7-Zip** | missing → baseline adds |
| SVG | resvg + chafa | missing → baseline adds |
| video (`.mp4`) | ffmpeg + chafa | ffmpeg **gated** behind `installMediaTools` |
| HEIC / JPEG-XL / fonts | ImageMagick ≥7.1.1 + chafa | **gated** behind `installMediaTools` |
| json / text / std images | jq / built-in | already always-installed |

**User decisions:** (1) keep ffmpeg + ImageMagick **gated** behind `installMediaTools`
(default off; forced off on server/minimal) — just document the yazi tie-in. (2) **Add EPUB + dmg
previewer rules** (pandoc is already installed everywhere; 7zip lands in the baseline → no new
install cost).

## Changes

### 1. Baseline preview deps — `dot_ansible/roles/devtools/tasks/main.yml` (always-installed, next to yazi)

- **macOS** — add to the single big brew `name:` list (~L57-125): `chafa`, `poppler`,
  `sevenzip` (provides `7zz`), `resvg`. Update the `# Tools:` header comment (L3).
- **Linux (Debian/Ubuntu)** — new `# --- yazi preview deps ---` block near the yazi section (~L2227):
  - apt (`become: true`, `tags: [sudo]`): `chafa`, `poppler-utils`, `p7zip-full` (provides `7z`;
    yazi accepts `7zz` **or** `7z`).
  - `resvg` has no apt package → best-effort **linuxbrew** (`community.general.homebrew`) else
    `cargo install resvg`, wrapped `block:`/`rescue:`→warn (matches the eza/git-delta aarch64
    fallback idiom already in this file). SVG preview is simply absent if it can't install — non-fatal.

  These are **not** gated on `primary_shell`/`installMediaTools` — small, universally useful, and
  the direct fix for the reported errors on every machine.

### 2. EPUB + dmg previewer rules — `dot_config/yazi/yazi.toml`

Append to the existing `prepend_previewers` list. `piper` is already pinned → **no** new plugin,
**no** `init.lua`/`package.toml`/run-script change:

```toml
{ url = "*.epub", run = 'piper -- pandoc -f epub -t plain "$1" 2>/dev/null | head -n 500' },
{ url = "*.dmg",  run = 'piper -- ( 7zz l "$1" 2>/dev/null || 7z l "$1" 2>/dev/null ) | head -n 200' },
```

- `2>/dev/null` is **load-bearing** — piper renders any stderr as an error preview (same rule as
  the existing feather/sqlite fallbacks).
- `7zz || 7z` covers macOS `sevenzip` (`7zz`) vs Linux `p7zip-full` (`7z`).
- `.apk/.jar/.whl/.xpi/.zip/.tar.*` need **no** rule — yazi's built-in archive previewer handles
  them free once 7-Zip is installed (document this, don't add rules).

### 3. Docs (CLAUDE.md cross-file rules mandate same-commit updates)

- **NEW `docs/tools/yazi-previews.md`** — umbrella "yazi preview coverage" page: the
  format→tool→tier matrix above; the chafa-fallback explanation + native-protocol/tmux note
  (install a graphics terminal to auto-upgrade from ascii-art); the `installMediaTools` gating for
  video/HEIC **and** the Ubuntu-ImageMagick-v6 HEIC caveat; the EPUB/dmg rules; per-OS install
  (brew formulae vs apt packages vs resvg fallback). Cross-link ↔ `office-viewers.md`,
  `data-viewers.md`. Pitfall/repo-root links use absolute GitHub URLs (repo convention).
- **`mkdocs.yml`** — nav entry (en + zh-TW) next to Office/Data viewers; then
  `uv run mkdocs build --strict`.
- **`docs/this_repo/tool-managers.md`** — A–Z index rows: `chafa`, `poppler`, `sevenzip`/`7zip`,
  `resvg` (mechanism: **devtools** — brew macOS / apt Linux); update the devtools Tools list.
- **`CLAUDE.md`** — extend the existing yazi-preview contract row: add the `yazi-previews.md`
  reference, the runtime-tool deps (chafa/poppler/7zip/resvg always; ffmpeg/ImageMagick gated), and
  the two new epub/dmg piper rules.
- **`README.md`** — extend the yazi/preview bullet: images, PDF, video, archives, ebooks.

## Critical files

- **Functional:** `dot_ansible/roles/devtools/tasks/main.yml`, `dot_config/yazi/yazi.toml`
- **Reused as-is (no edit):** `dot_config/yazi/{init.lua,package.toml,keymap.toml}`, `piper` plugin,
  `.chezmoiscripts/global/run_onchange_after_45_yazi_plugins.sh.tmpl`, the `media_tools` role
  (ffmpeg/ImageMagick stay gated — deliberate)
- **Docs:** new `docs/tools/yazi-previews.md`, `mkdocs.yml`, `docs/this_repo/tool-managers.md`,
  `CLAUDE.md`, `README.md`

## Verification

1. **Confirm formula names + the fix on this mac:** `brew install chafa poppler sevenzip resvg`
   then `command -v chafa 7zz pdftoppm resvg`. (This mac already has ffmpeg/magick, so pdf/mp4/heic
   should render as soon as chafa is present.)
2. **Parse gate:** `taplo check dot_config/yazi/yazi.toml` + `python3 -c 'import tomllib …'`.
3. **Ansible:** `ansible-playbook --syntax-check` the devtools role; run the new tasks narrowly
   (`--tags`/check-mode) where possible. If a host/cred is missing, say so explicitly.
4. **Docs:** `uv run mkdocs build --strict`.
5. **Piper-command sanity (headless-OK):** run each new rule body standalone —
   `pandoc -f epub -t plain book.epub | head`, `7zz l some.dmg | head`.
6. **Real-terminal smoke (can't run headless — sandbox yazi aborts with os error 6):** launch
   `yazi` and hover a png / pdf / mp4 / .zip / .dmg / .epub / .svg / .heic. Expect
   images/pdf/video as chafa ascii-art (or inline in a graphics terminal), archive + dmg listings,
   epub text, svg render. Confirm a plain `.txt`/`.json` still previews normally.

## Notes / follow-ups

- **Native inline images vs chafa:** chafa gives universal ascii-art previews (works over
  tmux/ssh/any terminal). For crisp inline images use a graphics-capable terminal
  (Ghostty/Kitty/iTerm2/WezTerm) — yazi auto-upgrades the adapter; over tmux the terminal must
  support Kitty-graphics passthrough (repo already sets `allow-passthrough on`). Documented, not coded.
- **Ubuntu HEIC/font:** apt ImageMagick is v6 (no unified `magick`, weak HEIC) → those previews may
  not work on Ubuntu even with `installMediaTools=true`. Documented as a known caveat; v7 needs a
  PPA/build (out of scope).
