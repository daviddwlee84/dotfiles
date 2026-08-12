## Context

Herdr can enumerate panes and read each pane's visible screen or retained scrollback, but it has no first-class cross-pane content search. The current `tv herdr-*` channels search metadata only; pane text appears only in previews. The goal is to package the proven `herdr pane list → pane read → rg` pipeline into a reliable, scriptable `herdr-grep` that identifies the exact session/workspace/tab/pane containing each match, supports named or all running local sessions, and distinguishes a clean no-match from an incomplete scan.

This must preserve the existing socket-routing model in `dot_config/shell/24_herdr.sh` and content-source vocabulary in `dot_config/herdr/executable_pane-copy.sh`, while remaining callable from any shell, SSH command, or future picker. Existing uncommitted work in the repository—especially documentation files—must be preserved through surgical edits.

## Recommended implementation

### 1. Add a standalone Python CLI

Create `dot_dotfiles/bin/executable_herdr-grep` as a self-contained, stdlib-only Python 3 executable (`argparse`, `dataclasses`, `json`, `os`, `shutil`, `subprocess`). Use external `rg` as the matcher, but parse Herdr and ripgrep JSON in Python; do not add a `jq` dependency and do not source interactive shell configuration.

Public v1 interface:

```text
herdr-grep [OPTIONS] PATTERN
herdr-grep --list-sessions

-F, --fixed-strings
-i, --ignore-case
--source {visible,recent,recent-unwrapped}   # default: recent
--visible                                   # alias for --source visible
--session NAME
--all-sessions
--json
-h, --help
```

Contract:

- A positional pattern is a ripgrep regex unless `-F` is supplied; `-i` composes with either mode.
- `--source recent` is the default retained-scrollback search, matching the established scrollback-copy behavior. `recent-unwrapped` is opt-in for searches affected by terminal hard wrapping.
- `--source` and `--visible` are mutually exclusive; `--session` and `--all-sessions` are mutually exclusive.
- A leading-dash pattern uses the conventional `herdr-grep -- -pattern` form.
- `--list-sessions` prints sorted running session names, one per line, for both-shell completion and does not require `rg`.
- Keep v1 one-shot and local-socket scoped: no `--host`, watch mode, context flags, pane filters, TSV, Television channel, or keybinding. Remote automation is `ssh HOST herdr-grep ...`; `herdr --remote` remains an interactive attach mechanism, not pane-command RPC.

### 2. Reuse Herdr's existing routing semantics

Port the behavior—not the shell function itself—of `_herdr_session_target` in `dot_config/shell/24_herdr.sh:80-121`:

- Parse `herdr session list --json` as `{ "sessions": [...] }`; treat invalid JSON/schema as an operational error.
- With no selector, leave the inherited environment untouched. An ambient `HERDR_SOCKET_PATH` therefore continues to target the current Herdr session; without it, Herdr uses the default socket. Resolve the display session name by matching the ambient socket, falling back to `default` as the existing helper does.
- `--session NAME` requires one exact, running entry with a non-empty authoritative `socket_path` and sets `HERDR_SOCKET_PATH` only in copied child environments.
- `--all-sessions` selects only running entries, sorts them by name, and scopes the corresponding socket separately for every child call. Stopped entries are skipped; an empty running set is a complete no-match.
- Never split hierarchical IDs to infer relationships. Take `workspace_id`, `tab_id`, and `pane_id` directly from `herdr pane list`, following `dot_config/television/cable/herdr-agent-panes.toml` and the warning in `dot_config/herdr/executable_space-root.sh`.

For each target session, run `herdr pane list`, validate `.result.panes`, sort panes by `(workspace_id, tab_id, pane_id)`, and read each pane sequentially with:

```text
herdr pane read PANE_ID --source SOURCE --format text
```

Retain `agent_status`, `foreground_cwd`, and `cwd` from pane-list metadata. Decode terminal output as UTF-8 with replacement so one invalid byte cannot crash the scan. A pane disappearing between list and read is a recoverable partial-scan error, not a clean no-match.

### 3. Use ripgrep as a deterministic internal matcher

Build argv arrays only—never `shell=True`—around:

```text
rg --no-config --json --text [-F] [-i] -- PATTERN
```

- Resolve `herdr` and `rg` up front with `shutil.which` (`rg` is unnecessary for `--list-sessions`).
- Preflight the pattern once against empty stdin: ripgrep exit 0/1 means valid; exit 2 means an invalid regex or invocation. This prevents repeating one syntax error for every pane.
- For each pane, feed captured text on stdin. Exit 0 yields JSON match events; exit 1 means no match; any other status or malformed event records a pane error and scanning continues.
- Accept a pane's matches only after its complete ripgrep JSON stream validates, avoiding half-trusted pane output.
- Sort final records by `(session, workspace_id, tab_id, pane_id, line_number, first_submatch_byte)` so output is stable regardless of fixture/order changes.

### 4. Define stable human, JSON, and exit contracts

Human output is one line per matching captured line, with the full coordinate repeated so it remains useful when piped:

```text
[session=default workspace=w1 tab=w1:t2 pane=w1:p4] 183:matched text
```

A line with multiple occurrences is printed once. Remove only its terminating newline; emit no headings, colors, summaries, or no-match message. The line number is one-based within the selected pane capture, not a persistent pane coordinate.

`--json` emits one valid JSON document with:

- top-level `schema_version`, query/source/mode fields, sorted targeted session names, `complete`, `matches`, and `errors`;
- each match's `session`, `socket_path`, `workspace_id`, `tab_id`, `pane_id`, `agent_status`, `foreground_cwd`, `cwd`, capture-relative `line_number`, `line`, and all ripgrep `submatches` (`text`, zero-based half-open UTF-8 byte offsets);
- stable error objects with `scope` (`global|session|pane`), nullable session/pane identifiers, operation, and message.

After successful argument parsing, `--json` must remain valid even for dependency, discovery, selected-session, or partial-scan failures. Human mode sends diagnostics to stderr and preserves good stdout matches.

Use grep-style status codes:

- `0`: at least one match and the scan completed;
- `1`: no matches and the scan completed;
- `2`: usage/dependency/invalid-regex/malformed-Herdr-data/unavailable-session error, or any incomplete scan.

A partial failure keeps successful matches, sets JSON `complete=false`, prints deterministic warnings in human mode, and returns 2 even when another pane matched.

### 5. Add paired shell completions

Create synchronized Strategy-B completions:

- `dot_config/zsh/tools/59_herdr_grep_completion.zsh`
- `dot_config/bash/59_herdr_grep_completion.bash`

Mirror the dynamic-candidate pattern used by `54_wake_completion.{zsh,bash}`:

- complete every public flag and the three source values;
- dynamically complete `--session` from `herdr-grep --list-sessions`, swallowing failures;
- do not enumerate candidates for `PATTERN`;
- include twin-file comments and command-presence guards.

Add `herdr-grep` to the in-house CLI table and dynamic-candidate notes in `docs/zsh/zsh-completions.md`. The existing zh-TW completion page does not contain the canonical Section-F inventory, so it does not need a synthetic partial mirror for this change.

### 6. Add offline black-box coverage

Create `tests/unit/herdr_grep.bats`, reusing `setup_path_stub`/`cleanup_path_stubs` from `tests/test_helper.bash` and the argv-capture style in `tests/unit/ghget.bats`.

Use a fixture-driven fake `herdr` that logs argv plus `HERDR_SOCKET_PATH` and returns session-, socket-, and pane-specific JSON/text. Wrap the saved real `rg` to log its argv while preserving real matching semantics; invoke the source script through an absolute Python interpreter for missing-dependency tests.

Cover these groups:

- parsing/help: missing or leading-dash pattern, unknown/conflicting flags, help/completion option agreement;
- sources/matching: default `recent`, visible/unwrapped overrides, regex, fixed-string, case-insensitive, multiple occurrences on one line, Unicode and terminal-invalid bytes;
- routing: default without socket, ambient named socket, explicit running/missing/stopped session, all-running sessions, stopped-session skip, no running sessions, and child-only env overrides;
- data integrity: malformed session/pane JSON, wrong schema, malformed pane entries, IDs that cannot be inferred by string splitting, deterministic shuffled input;
- outcomes: exact human coordinates, JSON schema/content/offsets, clean no-match, invalid regex before pane enumeration, disappearing pane, failed session, missing dependencies, partial matches with exit 2;
- completion helper: `--list-sessions` emits only sorted running names and does not require `rg`.

### 7. Update user-facing and agent-facing documentation

Edit existing pages rather than creating a new MkDocs page:

- `docs/tools/herdr.md` and `docs/tools/herdr.zh-TW.md`: add a pane-content-search section near named-session/capture documentation with examples, sources, match modes, human/JSON shapes, status codes, partial/race behavior, retention limits, leading-dash syntax, SSH-side remote usage, and the explicit non-goal that existing `tv herdr-*` channels do not index content.
- `README.md`: extend the existing Herdr managed-surface bullet to mention the deployed `herdr-grep` capability.
- `docs/shells/aliases.md`: add a `CLI (bin)` inventory row with completion files and examples; do not add a short alias (`hg` conflicts with Mercurial).
- `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`: hand-add `herdr-grep` to the in-house CLI/Herdr inventory because the prose is not auto-generated.

No changes are needed to `mkdocs.yml` (the bilingual Herdr page is already in nav), tool-manager inventories (Herdr, Python, and ripgrep are already managed), `dot_config/shell/24_herdr.sh`, Herdr config/keybindings, or Television channels.

## Verification

1. Syntax-check the Python source without leaving `__pycache__` in the repo (compile the loaded source or direct pycache to a temporary directory).
2. Run `zsh -n` and `bash -n` on the paired completion files; run applicable pre-commit checks on all touched files.
3. Run `bats tests/unit/herdr_grep.bats`, then `just bats`. Compare full-suite failures by test name against the known clean baseline rather than requiring the existing seven baseline failures to disappear.
4. Run `uv run mkdocs build --strict`; compare against the known baseline warnings and require no new warning/error attributable to this change.
5. Verify chezmoi mapping/rendering with `chezmoi cat ~/.dotfiles/bin/herdr-grep` and `chezmoi diff` without applying unrelated working-tree changes.
6. If a live Herdr server remains available, smoke-test source and rendered CLI behavior with `--help`, `--list-sessions`, a deliberately impossible `--visible -F` query (expect 1), a known matching query (expect full coordinate), and `--json | jq -e` validation. If no server is available, report the skipped live validator explicitly; the offline Bats suite remains authoritative.
