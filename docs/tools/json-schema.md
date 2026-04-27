# JSON Schema in this repo

[JSON Schema](https://json-schema.org/) is the open standard for describing the shape of a JSON document. When a config file declares `$schema`, editors with JSON language support (VS Code, Cursor, JetBrains, Neovim's `jsonls`, Sublime LSP) automatically pick up autocomplete, hover docs, and red-squiggle validation — zero extra setup, no per-project config. This page covers how the convention is used in this repo today and what to do if we ever want to author our own.

## TL;DR

| Concept | URI / location | Where it shows up |
|---|---|---|
| JSON Schema standard | <https://json-schema.org/> (current draft: 2020-12) | The grammar `$schema` claims compliance with |
| Community schema registry | <https://www.schemastore.org/json/> | Editors look here automatically by filename match |
| `$schema` field (instance side) | Inside a *config file* — points at the schema | Tells editors "validate me against this schema" |
| `$schema` field (schema side) | Inside a *schema document* — points at the JSON Schema dialect | Tells JSON Schema validators which dialect to parse |
| `$docs` field | Non-standard — Claude Code convention | Not interpreted by JSON Schema; pure human signpost |

The single field name `$schema` plays **two** roles depending on which file it sits in. Inside a config (e.g. `~/.claude/keybindings.json`), it's a claim "this instance conforms to schema X". Inside a schema document, it's a claim "I am written in JSON Schema dialect Y" (e.g. `https://json-schema.org/draft/2020-12/schema`). Easy to confuse the two.

## How editors discover schemas

Two pickup paths, in order:

1. **Inline `$schema` in the file**: highest precedence. Whatever URI the file declares wins. The editor fetches the schema (cached) and uses it.
2. **Filename / glob match against a registered schema catalog**: SchemaStore is the de-facto registry — VS Code's built-in `json` extension ships its catalog, JetBrains and Neovim plugins read the same. Filenames like `package.json`, `tsconfig.json`, `.eslintrc.json` light up automatically because SchemaStore maps the glob to a schema URI.

For files that aren't in SchemaStore (or aren't named conventionally), inline `$schema` is the only practical path. Hence the convention of writing it at the top of the file.

## Existing usages in this repo

| File | Schema URI | Source | Rationale |
|---|---|---|---|
| `~/.config/opencode/opencode.json` | `https://opencode.ai/config.json` | Upstream OpenCode | Vendor-hosted; OpenCode's own server serves the schema. Pinned in [`agents/opencode.overlay.json`](../../.chezmoitemplates/agents/opencode.overlay.json). |
| `~/.config/opencode/tui.json` | `https://opencode.ai/tui.json` | Upstream OpenCode | Same pattern — separate schema for the TUI subset. Pinned in [`agents/opencode.tui.overlay.json`](../../.chezmoitemplates/agents/opencode.tui.overlay.json). |
| `~/.claude/keybindings.json` | `https://www.schemastore.org/claude-code-keybindings.json` | SchemaStore | Community-curated; SchemaStore is the canonical home for schemas of well-known config formats. Pinned via [`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json) — see [Claude Code keybindings](claude-code-keybindings.md). |

Two flavours, two lessons:

- **Vendor-hosted is the right default for files we don't own.** OpenCode owns the format → OpenCode hosts the schema → we just point at it.
- **SchemaStore is the right default when the upstream tool didn't bother publishing a schema themselves.** SchemaStore PRs are usually accepted within a week and pin themselves to a specific path; once merged, every editor in the world knows about it.

## Authoring our own schema (if we ever need to)

If we add a JSON config file *we* own — e.g. a hypothetical `~/.config/dotfiles/preferences.json` or a JSON-shaped output from one of our scripts — and we want editors to validate it, the workflow is:

### 1. Write the schema document

A schema is just a JSON file describing the shape:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://daviddwlee84.github.io/dotfiles/_schemas/preferences.schema.json",
  "title": "dotfiles preferences",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "theme": {
      "type": "string",
      "enum": ["light", "dark", "auto"],
      "default": "auto",
      "description": "UI colour scheme. `auto` follows the system."
    },
    "shortcuts": {
      "type": "object",
      "additionalProperties": { "type": "string" },
      "description": "Map of action-name → key combo."
    }
  },
  "required": ["theme"]
}
```

Top-level fields:

- `$schema` (the dialect, not the instance reference) — pin to a JSON Schema draft. `2020-12` is current.
- `$id` — the canonical URI the schema will live at. **This must match where it actually gets served**, otherwise validators that resolve `$ref`s against `$id` will 404.
- `title`, `type`, `properties`, `required`, `additionalProperties`, `enum`, `default`, `description` — the actual shape grammar.

### 2. Host it somewhere stable

Three reasonable options, in increasing order of effort + reach:

| Host | URI shape | When to use |
|---|---|---|
| Raw GitHub | `https://raw.githubusercontent.com/<owner>/<repo>/main/path/foo.schema.json` | Quickest. Cached aggressively by GitHub; no ETag-based revalidation. Fine for personal use. |
| MkDocs site | `https://daviddwlee84.github.io/dotfiles/_schemas/foo.schema.json` | Already deployed on push-to-main via `.github/workflows/docs.yml`. Add the file under `docs/_schemas/` and reference via the published URL. Stable, versioned with the site, hot-reloads on `mkdocs serve`. |
| SchemaStore PR | `https://www.schemastore.org/foo.json` | If the format is reusable across projects. Submit a PR to [SchemaStore/schemastore](https://github.com/SchemaStore/schemastore). Once merged, every editor in the world auto-discovers it by filename. |

For repo-private configs, the MkDocs option is the sweet spot — already infrastructure we operate, already on a CDN, already on the same versioning cadence as the configs themselves.

To use it: drop the schema under `docs/_schemas/` (a directory MkDocs will deploy verbatim because we set `not_in_nav: |\n  /_snippets/` and the `_schemas/` prefix won't match any nav globs), then reference `https://daviddwlee84.github.io/dotfiles/_schemas/<name>.schema.json` from the config file. Note: `docs/_snippets/` already exists for `pymdownx.snippets`; if we ever start hosting schemas, mirror that pattern with a sibling `docs/_schemas/` directory and confirm it survives the strict build.

### 3. Reference it from the instance

Top of the config file:

```json
{
  "$schema": "https://daviddwlee84.github.io/dotfiles/_schemas/preferences.schema.json",
  "theme": "dark"
}
```

VS Code / Cursor will fetch and cache the schema on next file open; autocomplete + validation light up immediately.

### 4. Iterate

Schemas are append-only friendly: adding new optional fields with `default` values is backwards-compatible. Removing or tightening a field (e.g. narrowing an `enum`) is a breaking change — the same Hyrum's Law applies as for any API.

## The `$docs` extension

Some tools (Claude Code's `keybindings.json` is one example) include a sibling `$docs` URI alongside `$schema`. This is **not** part of JSON Schema and is ignored by validators. It exists purely as a human-readable signpost — "the schema is here for machines, the prose docs are here for people". If we author our own schema, we can adopt the same convention; editors won't complain (unknown top-level fields with `$` prefixes are tolerated by default in most schemas as long as the schema doesn't declare `additionalProperties: false` at the root).

If we want to be strict, declare `$docs` explicitly in our schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://daviddwlee84.github.io/dotfiles/_schemas/preferences.schema.json",
  "type": "object",
  "properties": {
    "$schema": { "type": "string", "format": "uri" },
    "$docs": { "type": "string", "format": "uri", "description": "Human-readable documentation URL." },
    "theme": { "type": "string", "enum": ["light", "dark", "auto"] }
  },
  "additionalProperties": false
}
```

This both documents the field and prevents `additionalProperties: false` from rejecting it.

## See also

- [json-schema.org → Getting started](https://json-schema.org/learn/getting-started-step-by-step) — official walkthrough.
- [SchemaStore catalog](https://www.schemastore.org/json/) — browse what's already covered before authoring a new schema.
- [SchemaStore contributing guide](https://github.com/SchemaStore/schemastore/blob/master/CONTRIBUTING.md) — submission rules for community schemas.
- [`docs/tools/claude-code-keybindings.md`](claude-code-keybindings.md) — concrete in-repo example: how the SchemaStore-hosted Claude Code keybindings schema is referenced via the `modify_keybindings.json` overlay.
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — sibling: how the OpenCode vendor-hosted schemas are pinned via the `modify_opencode.json.tmpl` and `modify_tui.json.tmpl` overlays.
