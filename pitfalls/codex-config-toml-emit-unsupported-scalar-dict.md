# `chezmoi apply` dies on `.codex/config.toml` with `unsupported scalar type for TOML emit: dict`

**Symptoms** (grep this section):
- `chezmoi apply` (or `chezmoi apply --init`) prints a Python traceback ending in
  `TypeError: unsupported scalar type for TOML emit: dict`
- The failing frames are all `File "<stdin>", line NN` — no filename, because
  the script is piped to `python -` from a chezmoi `modify_` template
- `chezmoi: .codex/config.toml: exit status 1`
- Every other file applies fine; only Codex's config is skipped
- `chezmoi diff ~/.codex/config.toml` fails the same way

```
Traceback (most recent call last):
  File "<stdin>", line 140, in <module>
  File "<stdin>", line 111, in emit_table
  File "<stdin>", line 105, in emit_table
  File "<stdin>", line 92, in fmt_scalar
  File "<stdin>", line 92, in <genexpr>
  File "<stdin>", line 93, in fmt_scalar
TypeError: unsupported scalar type for TOML emit: dict
chezmoi: .codex/config.toml: exit status 1
```

**First seen**: 2026-07 (codex-cli 0.141.0, peon-ping installed at `~/.openpeon`)
**Affects**: any machine where peon-ping's Codex adapter has run
**Status**: fixed — the emitter in
[`dot_codex/modify_config.toml.tmpl`](../dot_codex/modify_config.toml.tmpl)
now handles arrays-of-tables; regression test in
[`tests/unit/agent_overlays.bats`](../tests/unit/agent_overlays.bats)

## Root cause

`~/.codex/config.toml` is a `modify_` target: chezmoi pipes the live file in,
the script deep-merges a managed overlay, and prints the result. The merge goes
through `tomllib` (read) plus a **hand-rolled** TOML writer, because `jq`
doesn't speak TOML and `mikefarah/yq`'s TOML emitter mangles keys like
`github@openai-curated`.

That writer was built for the schema Codex itself writes — scalars, nested
string-key tables — and its docstring said so out loud: *"no arrays-of-tables"*.

Then peon-ping's Codex adapter
(`~/.openpeon/hooks/peon-ping/scripts/codex-config.py`, run by the
`coding_agents` ansible role's `install.sh --openpeon`) appended this into the
same file:

```toml
[[hooks.SessionStart]]
matcher = "startup|resume|clear"

[[hooks.SessionStart.hooks]]
type = "command"
command = "if [ -f …/adapters/codex.sh ]; then … fi"
timeout = 30
```

`tomllib` decodes that as `{"hooks": {"SessionStart": [ {...} ]}}` — a **list of
dicts**. The writer classified any non-`dict` value as a scalar, so the list went
to `fmt_scalar`, which recursed into its elements and hit a `dict` it had no
branch for.

**The general shape**: a hand-rolled emitter for a file that has more than one
writer is a standing liability. It only knows the constructs it was written for,
and it fails *loudly and totally* (whole file skipped) rather than degrading.

## Fix

Extend the emitter, not the assumption. `is_table_array()` now splits a table's
keys three ways — scalars, plain sub-tables, arrays-of-tables — and
arrays-of-tables get real `[[header]]` blocks. `fmt_scalar` grew an inline-table
branch (for a dict inside a *mixed* or empty list, which has no `[[…]]`
spelling) and an RFC 3339 date-time branch, so the next foreign writer to use
either doesn't repeat this.

Two ordering rules are load-bearing and easy to break on a later edit:

1. **Plain sub-tables emit before arrays-of-tables at every level.** Codex
   writes `[hooks.state."<path>:session_start:0:0"]` as a sibling of
   peon-ping's `[[hooks.*]]` blocks. Emitting siblings first keeps each `[[…]]`
   block self-contained instead of depending on the reader's "last `[[…]]`
   element" cursor.
2. **A parent `[[hooks.<Event>]]` must be immediately followed by its
   `[[hooks.<Event>.hooks]]` handlers** — peon-ping's *uninstaller* scans for
   exactly that adjacency (`_hook_kind` / `_remove_hook_sections`).

## Comments are lost, and that's OK here

`tomllib` discards comments, so peon-ping's `# peon-ping Codex hooks begin` /
`# install_dir = …` markers vanish on the first successful apply. That does not
orphan its block: `codex-config.py` falls back to matching handler sections by
adapter path (`is_current_adapter_text`), so a later `install.sh` re-run still
finds and replaces its own hooks instead of duplicating them.

**Check this property before trusting the round-trip for any new installer**
that writes into a `modify_` target — a marker-only uninstaller would silently
accumulate duplicate blocks on every apply.

## Verify

```sh
chezmoi execute-template < dot_codex/modify_config.toml.tmpl > /tmp/m.sh
chmod +x /tmp/m.sh
/tmp/m.sh < ~/.codex/config.toml > /tmp/out.toml   # must exit 0

# idempotent? (chezmoi runs this every apply)
/tmp/m.sh < /tmp/out.toml | diff - /tmp/out.toml

# does Codex itself accept it?
tmp=$(mktemp -d); cp /tmp/out.toml "$tmp/config.toml"
CODEX_HOME="$tmp" codex debug models >/dev/null   # must exit 0
```

## Related

- [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md) — the
  Codex TOML merge and what the writer covers
- [`peon-ping-setup-escapes-home`](peon-ping-setup-escapes-home.md) — the other
  reason this repo doesn't let the peon-ping installer run unsupervised
- [`editor-overlay-flattens-empty-settings`](editor-overlay-flattens-empty-settings.md)
  — same family: a `modify_` overlay mangling a foreign writer's structure
