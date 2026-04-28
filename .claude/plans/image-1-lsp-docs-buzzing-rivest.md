# Plan: `docs/tools/lsp.md` — Language Server Protocol inventory & recommendations

## Context

The user is currently being prompted by claude-hud (statusline plugin, configured in `dot_claude/modify_settings.json`) to install `gopls-lsp` for `.go` files (screenshot in chat). They want to:

1. Understand LSP at a conceptual level.
2. Inventory **what's already installed** across the three LSP-providing surfaces this repo has.
3. Get a **reasoned recommendation list** for what else to enable, scoped to NeoVim and the coding agents (Claude Code, Cursor, OpenCode, Codex).

There is no current docs page covering LSP — the topic is scattered across `lazyvim.json`, `dot_claude/modify_settings.json`, `dot_ansible/roles/devtools/tasks/main.yml`, and `dot_config/nvim/lua/exact_plugins/example.lua` (the last is a LazyVim *example* file, inert: `if true then return {} end` on line 3). The new doc consolidates this into one navigable surface and is the right home for the "how do I add a new language server" cookbook.

This plan is **docs-only** (no behavior change). Concrete config edits (e.g. enabling `gopls-lsp@claude-plugins-official` or adding `lazyvim.plugins.extras.lang.go`) are intentionally out of scope — the docs document the *option*, the user picks. See "Open questions" at the end.

## What's actually wired up today (research findings)

Three LSP-providing surfaces exist:

### 1. NeoVim via Mason (auto-managed, downloaded to `~/.local/share/nvim/mason/`)

Plugin manager: `lazy.nvim` + `LazyVim` distribution. LSP infra plugins (`create_lazy-lock.json`):

- `nvim-lspconfig`, `mason.nvim`, `mason-lspconfig.nvim`
- `nvim-cmp` + `cmp-nvim-lsp`, `cmp-buffer`, `cmp-path`, `cmp-emoji`, `copilot-cmp`
- `conform.nvim` (formatting), `nvim-lint` (linting)
- `nvim-treesitter`, `nvim-treesitter-textobjects`, `nvim-ts-autotag`
- `lazydev.nvim` (Lua/nvim-API completion), `SchemaStore.nvim` (JSON/YAML schemas)

LazyVim language extras enabled in `dot_config/nvim/lazyvim.json`:

| Extra                           | What it pulls in (LSPs / formatters / linters)                                        |
| ------------------------------- | ------------------------------------------------------------------------------------- |
| `lazyvim.plugins.extras.lang.python`   | `basedpyright` (LSP), `ruff` (LSP+linter); also `venv-selector.nvim`             |
| `lazyvim.plugins.extras.lang.json`     | `jsonls` (LSP) + SchemaStore                                                     |
| `lazyvim.plugins.extras.lang.markdown` | `marksman` (LSP), `markdownlint-cli2`                                            |
| `lazyvim.plugins.extras.lang.toml`     | `taplo` (LSP)                                                                    |
| `lazyvim.plugins.extras.lang.docker`   | `dockerls`, `docker-compose-language-service` (LSPs)                             |
| `lazyvim.plugins.extras.formatting.black` | `black` formatter (not an LSP but registered via conform)                     |

LazyVim core defaults additionally install: `lua_ls` (always-on, via lazydev), `bashls` (auto-attaches to shell buffers when present).

User-overlay LSP config (`dot_config/nvim/lua/exact_plugins/example.lua`): **inert** — early-returns on line 3, kept as a reference template only.

### 2. Claude Code plugin marketplace (`@claude-plugins-official`)

Configured via `enabledPlugins` in `dot_claude/modify_settings.json` (lines 52–55):

- `pyright-lsp@claude-plugins-official: true` — enabled
- `claude-hud@claude-hud: true` — enabled (this is the plugin showing the popup in the screenshot)

The hook-aware deep-merger (lines 86–108) preserves any plugins/hooks Claude itself or CodeIsland adds at runtime. See [`docs/tools/agent-overlays.md`](../../docs/tools/agent-overlays.md). The `gopls-lsp` recommendation in the screenshot comes from the same official marketplace; enabling it = adding `"gopls-lsp@claude-plugins-official": true` to that overlay.

### 3. System-installed (ansible / brew)

- `taplo` — `dot_ansible/roles/devtools/tasks/main.yml` (TOML LSP/formatter, also usable as CLI)
- `node` (LTS), `tree-sitter-cli` — `dot_ansible/roles/lazyvim_deps/tasks/main.yml` (LSP *runtime prerequisites*, not LSPs themselves)

Mise toolchains (`dot_config/mise/config.toml.tmpl`) provide LSP **prerequisites** but not LSPs themselves: `node lts`, `rust latest`, `dotnet latest`, `ruby 3`. Adding `lazyvim.plugins.extras.lang.{rust,go,…}` does not require new ansible work because mise + node are already there for Mason to use.

## Final docs page outline

File: `docs/tools/lsp.md` (~3-4KB, matches `docs/tools/ghostty.md` length norm).

```
# Language servers (LSP)

[1-paragraph intro: what LSP is, why it matters for editors/agents,
 link to https://microsoft.github.io/language-server-protocol/]

## The three LSP surfaces in this repo

[Brief table: surface | who manages it | where state lives | how to add one]

## Currently installed

### Via NeoVim + Mason
[Table from research findings above]
[Note about LazyVim extras vs hand-config; point at lazyvim.json
 and the inert example.lua as the override hook]

### Via Claude Code plugins
[List `enabledPlugins` entries; explain `@claude-plugins-official` marketplace;
 link agent-overlays.md for the hook-aware merger]

### Via ansible / system packages
[Just taplo today; explain when this surface is the right one
 — i.e. when the LSP is also a useful CLI tool]

## Runtime prerequisites (mise toolchains)
[node, rust, dotnet, ruby — already provisioned, so most LazyVim language
 extras "just work" without ansible changes]

## Recommended additions

[Per-language candidates with where to add them. Format each as:
 **<lang>** — what / where to enable / why or when to skip]

- **Go** — `lazyvim.plugins.extras.lang.go` (Mason-installs gopls + goimports)
  AND/OR `gopls-lsp@claude-plugins-official` for Claude Code. Not currently
  enabled despite the claude-hud popup.
- **Bash** — `bashls` auto-attaches if present; install via Mason (`:Mason` →
  search bash-language-server) or `lazyvim.plugins.extras.lang.bash` (no
  extras file needed; LazyVim handles bashls automatically when shfmt/shellcheck
  are present — both already installed by example.lua's commented mason list,
  but example.lua is inert; in practice bashls is missing).
- **Rust** — `lazyvim.plugins.extras.lang.rust` (rust toolchain via mise already
  installed; pulls rust-analyzer via Mason).
- **YAML** — `lazyvim.plugins.extras.lang.yaml` (yamlls + SchemaStore — high
  value for ansible/k8s/GitHub Actions files in this repo).
- **TypeScript** — `lazyvim.plugins.extras.lang.typescript` (vtsls; node already
  installed).
- **Lua** — already default via lazydev; no action needed.

[Then a parallel mini-list for Claude plugin marketplace LSPs the user might
 also want — only those that match the languages they actually edit]

## Adding a new LSP

### To NeoVim
1. `:LazyExtras` → toggle the `lang.<x>` row → `<CR>`. This rewrites
   `~/.config/nvim/lazyvim.json` in-place.
2. Because `dot_config/nvim/lazyvim.json` is NOT a `create_` / `modify_` file
   in the source state, chezmoi tracks it normally — `chezmoi re-add` or
   commit the diff to propagate the new extra to other machines.
3. Restart nvim; Mason auto-installs the new LSP binary on first use.

[Note: `create_lazy-lock.json` is a seed-once file — link
 docs/tools/chezmoi-prefixes.md → "create_". To refresh the lock baseline,
 `cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"`.]

### To Claude Code
Edit `dot_claude/modify_settings.json` overlay → `enabledPlugins` map → add
`"<plugin>@claude-plugins-official": true`. The hook-aware merger preserves
any hook entries CodeIsland or Claude adds at runtime.

### To ansible (system-wide CLI binary)
Only when the LSP doubles as a useful shell tool (taplo lints TOML in CI;
shfmt/shellcheck are linted shellscript-wide, etc.). Add to
`dot_ansible/roles/devtools/tasks/main.yml`. For nvim-only LSPs, prefer
Mason — keeps the binary out of `$PATH`.

## Cross-tool collisions

- Mason auto-installed `pyright-language-server` vs Claude's
  `pyright-lsp@claude-plugins-official`: separate processes, separate binaries
  (Mason → `~/.local/share/nvim/mason/bin/`, Claude plugin → its own
  bundled binary under `~/.claude/plugins/`). No conflict.
- `taplo` exists both as a Mason package (auto-installed by `lang.toml`) AND
  as an ansible-managed brew/apt install. Two binaries; both in `$PATH` is
  fine.

## Verification

- NeoVim: `:Mason` lists installed servers; `:LspInfo` shows the active server
  attached to the current buffer.
- Claude Code: `/plugin list` (or inspect `~/.claude/settings.json`
  `enabledPlugins` after `chezmoi apply`).
- System CLI: `taplo --version`, `shellcheck --version`, etc.
- Docs build: `uv run mkdocs build --strict`.

## See also

- [agent-overlays](agent-overlays.md) — how the Claude Code overlay merges,
  including `enabledPlugins` and the `@claude-plugins-official` marketplace.
- [chezmoi-prefixes](chezmoi-prefixes.md) — why `lazy-lock.json` uses `create_`.
- pitfalls/tree-sitter-cli-empty-native-binary.md — tree-sitter postinstall
  flake (LSP-adjacent toolchain risk).
- pitfalls/nvim-fs-find-enoent-stale-cwd.md — Neovim plugin-ecosystem
  stability example.
```

## Files to modify

| File | Change |
| --- | --- |
| `docs/tools/lsp.md` | **NEW** — content per outline above |
| `mkdocs.yml` | Add nav entry under `Tools` → `Editor & agents` (line 135-145 area). Insert at line ~145 (alphabetical between `LLM: tools/llm.md` and the start of the next subsection): `      - Language servers (LSP): tools/lsp.md`. Keep alphabetical-within-section convention. |

That's it — two files. No code changes, no config behavior changes, no ansible role changes, no NeoVim config changes.

## Reused references / cross-links to keep accurate

- `dot_config/nvim/lazyvim.json` — source of truth for active extras.
- `dot_config/nvim/create_lazy-lock.json` — plugin pin manifest (seed-once via `create_` prefix).
- `dot_claude/modify_settings.json:52-55` — `enabledPlugins`.
- `dot_ansible/roles/devtools/tasks/main.yml` — `taplo` install.
- `dot_ansible/roles/lazyvim_deps/tasks/main.yml` — `node` + `tree-sitter-cli`.
- `dot_config/mise/config.toml.tmpl` — LSP runtime prereqs.
- `docs/tools/agent-overlays.md` (Claude overlay & merger).
- `docs/tools/chezmoi-prefixes.md` (`create_` / `modify_` semantics).
- `pitfalls/tree-sitter-cli-empty-native-binary.md`, `pitfalls/nvim-fs-find-enoent-stale-cwd.md`.

## Verification (post-implementation)

```bash
uv run mkdocs build --strict
```

`validation.links.not_found: info` (from `mkdocs.yml:14`) lets relative-to-repo links (`../../dot_config/...`, `../../pitfalls/...`) pass; genuine internal nav-page misses still error. The new page only adds same-section relative links (`agent-overlays.md`, `chezmoi-prefixes.md`) plus `pitfalls/...` (out-of-site, will degrade to info).

Optional: open `docs/tools/lsp.md` in a renderer (Glow, GitHub preview) to spot-check tables.

## Open questions / out of scope

- **Should this PR also enable `gopls-lsp@claude-plugins-official` and/or `lazyvim.plugins.extras.lang.go`?** Plan above is docs-only. Easy to bundle the toggle if the user prefers (~3-line diff in `dot_claude/modify_settings.json` + 1 line in `dot_config/nvim/lazyvim.json`).
- **Other languages to actually enable now?** YAML and Bash are the highest-value gaps for *this repo's own* content (lots of YAML in `dot_ansible/`, lots of bash in `dot_*scripts/`). Plan documents them as recommendations; toggling them is a one-liner each.
- **README.md mention?** README already says "see `docs/`" generically; adding an LSP entry is optional and not load-bearing. Skipping by default.
