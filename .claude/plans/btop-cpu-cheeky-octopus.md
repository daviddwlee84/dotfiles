# Fix btop crash + bring btop config under chezmoi management

## Context

`btop` crashes on launch for the user. ChatGPT diagnosed a Unix-permissions problem on
`~/.config/btop/themes` (root-owned / chmod-broken) and prescribed `sudo chown`/`chmod`.
**That diagnosis is wrong** — verified below. Separately, btop's config is currently *not*
managed by this dotfiles repo, and the user wants a curated, version-controlled baseline
(theme + process view + vim navigation) that survives across machines.

This plan does two things:

- **Part A** — fix the crash (root cause is a shadowing snap, not file permissions).
- **Part B** — add `dot_config/btop/` to chezmoi with the user's chosen customizations,
  honoring the repo's cross-file maintenance contract.

## Root cause (confirmed by verbatim reproduction)

There are **three** `btop` binaries on PATH; the **snap** wins because `/snap/bin` (PATH pos 11)
precedes `~/.local/bin` (15) and `/usr/bin` (22):

| Binary | Source | Version | Confined? |
|---|---|---|---|
| `/snap/bin/btop` ← **runs** | snap, 3rd-party publisher `kz6fittycent` | 1.4.7 | **yes (AppArmor)** |
| `/usr/bin/btop` | apt (Ubuntu noble) | 1.3.0 | no |
| `~/.local/bin/btop` | repo's GitHub musl fallback (not currently present) | latest | no |

Running the snap under a properly-sized PTY reproduces the user's exact crash:

```
terminate called after throwing an instance of 'std::filesystem::__cxx11::filesystem_error'
  what():  filesystem error: directory iterator cannot open directory: Permission denied [/home/daviddwlee84/.config/btop/themes]
```

- The snap's `home` interface **cannot read hidden dirs** (`~/.config/...`). btop's
  `std::filesystem::directory_iterator` over `~/.config/btop/themes` hits the AppArmor denial
  → throws → uncaught → `abort()` → `IOT instruction (core dumped)`.
- The dir is **`daviddwlee84:daviddwlee84 drwxrwxr-x` (775)** — already user-owned and readable.
  ChatGPT's `chown`/`chmod` fix would change nothing; the denial is from snap confinement, not
  Unix perms. (`namei -l` confirmed no root-owned component.)
- The repo never installs the snap. On Linux it uses **apt (`dot_ansible/roles/devtools/tasks/main.yml:2644`) → GitHub musl static fallback (`:2664`)**. The macOS Homebrew block that lists btop (`:52`) is `when: os_family == "Darwin"` — macOS only.

## Part A — Fix the crash (no repo change required)

The repo's install path is already correct and `/usr/bin/btop` (apt 1.3.0) is installed and works
(it created a valid config in an isolated test). The crash is purely the snap shadowing it.

**Action (manual, one-time):**

```bash
sudo snap remove btop          # removes the confined 3rd-party shadow
# → /usr/bin/btop (apt 1.3.0) now wins on PATH; btop launches.
```

**Optional — newer version via a package manager (still honors "package-manager first"):**
linuxbrew is present and ships btop 1.4.7. `brew install btop` lands at
`/home/linuxbrew/.linuxbrew/bin/btop` (PATH pos 8) and auto-wins over everything, giving the same
1.4.x the snap provided, unconfined. Removing the snap afterward is then just cleanup.

**Not doing:** no ansible change to the btop install logic (apt→GitHub-musl fallback stays — it's
the user's stated priority and preserves the CentOS-7-no-root portability noted at `:2654`). Snap
removal stays a documented manual step, not a new ansible `snap state: absent` surface (repo is
install-only and doesn't manage snaps).

## Part B — Manage + customize btop in chezmoi

### Management strategy: seed-once (`create_`)

btop rewrites `~/.config/btop/btop.conf` on **every exit**. A plain-managed file would drift
(apt 1.3.0 vs brew 1.4.x emit different canonical files → fleet drift, which this repo avoids).
Use `create_` — chezmoi seeds once, then never touches it, so btop's rewrites cause **zero apply
drift**. This mirrors the repo's existing precedents `dot_config/nvim/create_lazy-lock.json` and
`dot_config/marimo/create_marimo.toml.tmpl`.

> **Prefix goes on the file, not the directory**: `dot_config/btop/create_btop.conf.tmpl`
> (NOT `create_dot_config/...`). It is `.tmpl` because `vim_keys` is templated (below).
> Ordering: `create_` first, `.tmpl` last.

### Customizations chosen by the user

Seed = the user's **current** `~/.config/btop/btop.conf` (a complete, valid config — preserves their
existing `presets`, `shown_boxes`, `update_ms = 2000`, `proc_sorting = "cpu lazy"`) with **four
overrides**:

| Key | From | To |
|---|---|---|
| `color_theme` | `"Default"` | `"catppuccin_mocha"` |
| `proc_tree` | `False` | `True` |
| `proc_cmdline` | `False` (default) | `True` |
| `vim_keys` | `False` | `{{ if .enableVimMode }}True{{ else }}False{{ end }}` |

`theme_background` stays `True` (user did **not** pick transparent).

`color_theme = "catppuccin_mocha"` silently falls back to Default unless the theme file is present —
so the vendored theme (below) must land in the **same** change.

### Files to create / change (ordered)

1. **`dot_config/btop/create_btop.conf.tmpl`** — NEW. Seed-once baseline: the user's full current
   config + the 4 overrides; `vim_keys` line templated on `.enableVimMode`. Booleans are
   Python-style `True`/`False`; string values keep quotes. **Never `chezmoi add` this** (would strip
   `create_`).
2. **`dot_config/btop/themes/catppuccin_mocha.theme`** — NEW, vendored (mirrors
   `dot_config/bat/themes/tokyonight_night.tmTheme`). Fetch from catppuccin/btop upstream
   (`themes/catppuccin_mocha.theme`). Plain `dot_` tracked file. **No** `run_onchange` cache-rebuild
   sibling — btop reads `.theme` directly at launch (unlike bat's `bat cache --build`).
3. **`README.md`** — EDIT. Add a "Config Files" bullet for `~/.config/btop/btop.conf` +
   `themes/catppuccin_mocha.theme` (catppuccin_mocha, proc tree + cmdline, vim_keys↔enableVimMode,
   `create_` seed-once so on-exit rewrites don't drift), modeled on the bat line. ("What You Get →
   Dev tools" already names btop — no change there.) *(CLAUDE.md cross-file rule: config files → README.)*
4. **`docs/tools/btop.md`** — NEW. Structure after `docs/tools/ghostty.md`: intro, "Managed config"
   (the `create_` rationale + refresh recipe), the `color_theme` vs `theme` naming gotcha, the
   vendored theme, and a prominent link to the snap-confinement pitfall.
5. **`docs/tools/btop.zh-TW.md`** — NEW i18n sibling. Open with the standard zh-TW terminology
   admonition (copy from `docs/tools/ghostty.zh-TW.md:1-6`); never translate code/flags/filenames.
6. **`mkdocs.yml`** — EDIT. Add `- btop (system monitor): tools/btop.md` under
   `nav: → Tools: → Shell & terminal:` (near Ghostty/Starship, ~`:245`), plus the matching
   `nav_translations` zh-TW label in the i18n block (~`:84`).
7. **`pitfalls/btop-themes-permission-denied-core-dumped.md`** — NEW (symptom-titled).
   **Symptoms** (verbatim, grep-able): `IOT instruction (core dumped)`,
   `terminate called after throwing an instance of 'std::filesystem::__cxx11::filesystem_error'`,
   `filesystem error: ... Permission denied [.../.config/btop/themes]`, `/snap/bin/btop`,
   publisher `kz6fittycent`. **Root cause**: snap AppArmor `home` interface can't read hidden dirs;
   the 775 user-owned perms are a **red herring** (call this out — ChatGPT misdiagnosed it).
   **Fix**: remove/shadow the snap so apt/`~/.local/bin`/brew btop wins. Add an alphabetical row to
   `pitfalls/README.md`'s index. *(Governed by the `project-knowledge-harness` convention: >15 min,
   silent, non-obvious, non-googleable.)*
8. **vim-mode catalog updates** (required because `vim_keys` is gated — same commit):
   - `docs/this_repo/vim-mode.md` — move btop out of the "not managed" list into the gated catalog
     table, with the marimo-style `create_` caveat (flipping `enableVimMode` later won't re-touch an
     existing seeded `btop.conf`; delete-and-reapply to re-seed).
   - `CLAUDE.md` — under the "`enableVimMode` gates shell + tmux vim" invariant, update the count
     ("7 gated templated files + 1 first-seed marimo.toml" → add btop.conf as a 2nd first-seed file).

### Refresh recipe (document in btop.md)

Neither `chezmoi add` (strips `create_`) nor `chezmoi re-add` (skips `create_`) updates the seed:

```bash
cp ~/.config/btop/btop.conf "$(chezmoi source-path ~/.config/btop/btop.conf)"
```

## Verification

1. **Crash fixed**: `sudo snap remove btop` (and/or `brew install btop`); `command -v btop` resolves
   to a non-snap path; `btop` launches in an interactive terminal without `core dumped`.
2. **Seed lands**: on this box btop.conf already exists, so to apply the curated seed once:
   `rm ~/.config/btop/btop.conf && chezmoi apply` → file recreated with catppuccin_mocha + tree.
   `chezmoi diff dot_config/btop` afterward shows no conf diff (create-only), only the theme file.
3. **Config is valid (per "validate with the app" invariant)**: launch btop on the fixed binary and
   confirm the catppuccin theme renders, tree view + command lines show, and `hjkl` navigates
   (when `enableVimMode = true`).
4. **Docs build**: `uv run mkdocs build --strict` passes (catches missing nav / i18n pairing /
   broken links).
5. **No drift over time**: open and quit btop a few times; `chezmoi diff` stays clean (proves the
   `create_` choice was correct).

## Out of scope / notes

- No change to the btop install logic in ansible (apt → GitHub musl fallback is correct and matches
  the user's "package-manager first, GitHub last" priority).
- Snap removal is a manual one-time step, not an ansible-managed removal.
- Leftover `~/snap/btop/` after removal is harmless.
