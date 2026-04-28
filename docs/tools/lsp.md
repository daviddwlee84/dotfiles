# Language servers (LSP)

The [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) is an editor-agnostic protocol for code intelligence (diagnostics, hover, go-to-definition, completion, rename, formatting, code actions). An editor (the *client*) launches a per-language *server* over stdio/TCP and asks it questions about the buffer; the server speaks one language well, the editor stays language-agnostic. Coding agents that read source under the hood (Claude Code, Cursor, OpenCode, Codex) increasingly piggyback on the same servers to get type-aware context instead of grep-only context.

This repo provisions LSP from **three independent surfaces**. Mixing surfaces is normal — each has different reach.

## The three LSP surfaces in this repo

| Surface | Who manages it | Where state lives | When to use |
|---|---|---|---|
| **NeoVim + Mason** | `mason.nvim` auto-downloads on demand | `~/.local/share/nvim/mason/bin/` | Editor-only intelligence inside `nvim`. Default for most languages. |
| **Claude Code plugin marketplace** | Claude Code, via the `enabledPlugins` map in `~/.claude/settings.json` | `~/.claude/plugins/` | Adds LSP context to the agent's buffer reads. Independent of the nvim install. |
| **System packages (ansible / brew)** | `dot_ansible/roles/devtools/`, Brewfiles | `$PATH` (e.g. `/opt/homebrew/bin/`, `~/.local/bin/`) | Only when the LSP doubles as a useful CLI (linter, formatter, CI tool). |

You can have the same server installed via two surfaces simultaneously — they run as separate processes from separate binaries, no conflict.

## Currently installed

### Via NeoVim (LazyVim extras)

Active extras live in [`dot_config/nvim/lazyvim.json`](../../dot_config/nvim/lazyvim.json). Each `lang.*` extra pulls in the relevant LSP, treesitter parser, formatter, and linter via Mason on first use:

| Extra | Languages covered | LSPs (via Mason) |
|---|---|---|
| `lazyvim.plugins.extras.lang.python` | Python | `basedpyright`, `ruff` |
| `lazyvim.plugins.extras.lang.json` | JSON / JSON5 / JSONC | `jsonls` (+ SchemaStore.nvim) |
| `lazyvim.plugins.extras.lang.markdown` | Markdown | `marksman` (+ `markdownlint-cli2`) |
| `lazyvim.plugins.extras.lang.toml` | TOML | `taplo` |
| `lazyvim.plugins.extras.lang.docker` | Dockerfile, docker-compose | `dockerls`, `docker-compose-language-service` |
| `lazyvim.plugins.extras.formatting.black` | Python (formatter only) | not an LSP — `black` via `conform.nvim` |

LazyVim's core spec also wires up **`lua_ls`** (Lua language server) automatically through `lazydev.nvim` — no extras file needed. SchemaStore.nvim is loaded once and shared by JSON / YAML LSPs.

LSP infra plugins from [`create_lazy-lock.json`](../../dot_config/nvim/create_lazy-lock.json): `nvim-lspconfig`, `mason.nvim`, `mason-lspconfig.nvim`, `nvim-cmp` + `cmp-nvim-lsp`, `conform.nvim` (formatting), `nvim-lint` (linting), `nvim-treesitter`, `lazydev.nvim`, `SchemaStore.nvim`.

> The file [`dot_config/nvim/lua/exact_plugins/example.lua`](../../dot_config/nvim/lua/exact_plugins/example.lua) is **inert** — line 3 is `if true then return {} end`. It's a reference template showing how to override LSP server settings, but it isn't loaded. Don't read it as the active config; the source of truth is `lazyvim.json` plus any non-example file under `lua/exact_plugins/`.

### Via Claude Code plugins

[`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) overlays `enabledPlugins` into `~/.claude/settings.json`:

```json
"enabledPlugins": {
  "pyright-lsp@claude-plugins-official": true,
  "claude-hud@claude-hud": true
}
```

- **`pyright-lsp@claude-plugins-official`** — Python LSP for Claude Code, sourced from the official marketplace.
- **`claude-hud@claude-hud`** — the statusline plugin that shows the "LSP Plugin Recommendation" prompt when you open a file whose extension matches a marketplace LSP that isn't installed yet (e.g. opening a `.go` file triggers a popup for `gopls-lsp@claude-plugins-official`).

The overlay deep-merges via a hook-aware `jq` script ([details](agent-overlays.md)) so Claude / CodeIsland runtime additions to `hooks.*` arrays are preserved instead of replaced.

### Via ansible / system packages

- **`taplo`** — installed by [`dot_ansible/roles/devtools/tasks/main.yml`](../../dot_ansible/roles/devtools/tasks/main.yml) (system-wide CLI: `taplo fmt`, `taplo lint`). Note: also auto-installed by `lazyvim.plugins.extras.lang.toml` into Mason. Two binaries, both fine.

Runtime prerequisites (not LSPs themselves, but most LSPs need them):

- `node` (LTS) and `tree-sitter-cli` from `dot_ansible/roles/lazyvim_deps/tasks/main.yml` — needed by Mason to install Node-based LSPs (jsonls, dockerls, vtsls, yamlls, bashls, …).
- mise toolchains in [`dot_config/mise/config.toml.tmpl`](../../dot_config/mise/config.toml.tmpl): `node lts`, `rust latest`, `dotnet latest`, `ruby 3`. Adding a `lang.go` / `lang.rust` extra later does not require new ansible work — Mason picks up the toolchain.

## Recommended additions

These are unenabled LSPs that would have noticeable value given the languages this repo itself contains and the languages the user edits frequently. Each item lists where to flip the switch — do it when you want it, not preemptively.

| Language | NeoVim path | Claude Code path | Notes |
|---|---|---|---|
| **Go** | `lazyvim.plugins.extras.lang.go` (gopls + goimports via Mason) | `gopls-lsp@claude-plugins-official` | This is the popup in the screenshot. Toolchain (Go) is **not** preinstalled by mise — the extra installs gopls but you need `go` in `$PATH` separately. |
| **YAML** | `lazyvim.plugins.extras.lang.yaml` (yamlls + SchemaStore) | n/a | High value for this repo: `dot_ansible/`, GitHub Actions, MkDocs. SchemaStore already loaded for JSON. |
| **Bash** | `lazyvim.plugins.extras.lang.bash` (bashls + shellcheck + shfmt) | n/a | High value for `dot_*scripts/` and `.chezmoiscripts/`. shellcheck is already used by pre-commit. |
| **Rust** | `lazyvim.plugins.extras.lang.rust` (rust-analyzer via Mason) | n/a | Rust toolchain already provisioned via mise. |
| **TypeScript** | `lazyvim.plugins.extras.lang.typescript` (vtsls) | n/a | Node already installed; the inert `example.lua` references the older `tsserver` setup, ignore it and use the modern extra. |
| **Lua** | already on (LazyVim default via lazydev) | n/a | No action. |

For Claude Code, the official marketplace ships an `*-lsp@claude-plugins-official` plugin per language; inspect available ones with `/plugin list` inside Claude or watch for claude-hud popups when opening unfamiliar file types. Enable only the ones for languages you actually edit in Claude — each adds startup cost.

## Adding a new LSP

### To NeoVim

1. Inside `nvim`, run `:LazyExtras`. Toggle the `lang.<language>` row with `<CR>`. LazyVim writes the change into `~/.config/nvim/lazyvim.json`.
2. `lazyvim.json` is a normal tracked file in this repo (no `create_` / `modify_` prefix), so propagate to other machines by committing the diff: `chezmoi re-add ~/.config/nvim/lazyvim.json` then `git -C "$(chezmoi source-path)" add` + commit.
3. Restart `nvim`; on first use of the language Mason auto-installs the binary. `:LspInfo` confirms the server attached.

`create_lazy-lock.json` is **seed-once** ([why](chezmoi-prefixes.md)) — `chezmoi apply` won't update it. To refresh the lock baseline after adding plugins:

```bash
cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"
```

### To Claude Code

Edit [`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) → add to the `enabledPlugins` map inside the `overlay` heredoc:

```json
"enabledPlugins": {
  "pyright-lsp@claude-plugins-official": true,
  "claude-hud@claude-hud": true,
  "gopls-lsp@claude-plugins-official": true
}
```

Then `chezmoi apply ~/.claude/settings.json`. The hook-aware merger preserves any runtime entries Claude / CodeIsland have added to `hooks.*`.

### To ansible (system-wide CLI)

Only when the LSP also runs as a CLI tool you want in `$PATH` (e.g. linting in pre-commit, CI). Add to `dot_ansible/roles/devtools/tasks/main.yml` following the existing `taplo` pattern. For nvim-only intelligence, prefer Mason — keeps the binary out of `$PATH` and lets nvim manage versions independent of the system package.

## Cross-tool notes

- **Mason `pyright-language-server` vs Claude `pyright-lsp@claude-plugins-official`** — separate processes, separate binaries (Mason → `~/.local/share/nvim/mason/bin/`, Claude plugin → `~/.claude/plugins/`). The two clients (nvim, Claude) each spawn their own server; no shared state.
- **`taplo` ansible install vs Mason install** — same situation. The ansible binary is in `$PATH` for shell use (`taplo fmt some.toml`), the Mason binary is what nvim's `lspconfig` spawns. Keeping both is intentional.
- **Toolchain ≠ LSP** — `mise` provides language runtimes, not LSPs. `node lts` lets Mason install JS-based LSPs; `rust latest` makes `lazyvim.plugins.extras.lang.rust` work without further setup.

## Pitfalls (LSP-adjacent)

- [`pitfalls/tree-sitter-cli-empty-native-binary.md`](../../pitfalls/tree-sitter-cli-empty-native-binary.md) — npm postinstall sometimes downloads an empty `tree-sitter` binary; affects LSP-adjacent syntax tooling. Aggregate health check covers it.
- [`pitfalls/nvim-fs-find-enoent-stale-cwd.md`](../../pitfalls/nvim-fs-find-enoent-stale-cwd.md) — Neovim 0.12 startup crash from plugins (avante, lualine) calling `vim.fs.find` with a stale cwd. Not LSP-specific but representative of the plugin-ecosystem fragility you'll hit when adding new servers.

## Verification

```bash
# In nvim
:Mason       # list installed servers and their state
:LspInfo     # show the active server attached to the current buffer
:checkhealth lsp

# Claude Code
ls ~/.claude/plugins/                 # installed plugin trees
jq .enabledPlugins ~/.claude/settings.json

# System CLIs
taplo --version
shellcheck --version

# Docs (after editing this page)
uv run mkdocs build --strict
```

## See also

- [agent-overlays](agent-overlays.md) — how the Claude Code overlay merges, including `enabledPlugins` and the `@claude-plugins-official` marketplace.
- [chezmoi-prefixes](chezmoi-prefixes.md) — why `lazy-lock.json` uses `create_` and how to refresh the baseline.
- [agent-skills](agent-skills.md) — sibling extension surface for Claude Code (skills, not LSPs).
