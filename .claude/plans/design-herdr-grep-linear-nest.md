## Context

The committed `herdr-grep` CLI locates terminal content and reports exact Session / Workspace / Tab / Pane coordinates, but users must still inspect its textual output and navigate manually. The next step is a pipeline-style interactive mode:

```text
herdr-grep PATTERN → fzf over the filtered matches → exact pane focus → attach when outside Herdr
```

The user chose fzf rather than Television. Television 0.15.6 cannot pass its live query to a channel source, while fzf is a natural selector after `herdr-grep` has already performed the real regex/fixed-string search. This design therefore adds `herdr-grep --pick`, not a TV channel and not a separate all-lines indexer.

The picker must work both inside and outside Herdr. Inside, it jumps within the selected current session. Outside, it may search one/all running sessions, pre-focus the selected target, then attach like `hhere`. Herdr 0.7.5 has no direct `pane focus PANE_ID`, so ordinary split panes require a reusable exact-focus helper.

## Recommended implementation

### 1. Add `--pick` to `herdr-grep`

Extend `dot_dotfiles/bin/executable_herdr-grep` with an interactive output mode:

```text
herdr-grep --pick [OPTIONS] [PATTERN]
herdr-grep --pick --all-sessions 'error|failed'
herdr-grep --pick -F -i 'connection refused'
```

- `--pick` is mutually exclusive with `--json`.
- Existing `-F`, `-i`, `--source`, `--visible`, `--session`, and `--all-sessions` semantics remain unchanged.
- With a PATTERN, run the existing scan first and give only matching lines to fzf.
- Without a PATTERN, prompt once in an interactive TTY (`grep> `); blank/Esc is a quiet no-op. Missing PATTERN in a noninteractive context remains usage error 2.
- Do not introduce a second PATH CLI or a `grep-pick.sh`; keep query parsing, scan results, fzf row construction, source switching, selection, and attach behavior in the existing Python CLI.

Resolve `fzf` only when `--pick` is used. Resolve the focus helper from `HERDR_GREP_FOCUS_HELPER` when set (test/override hook), otherwise `~/.config/herdr/focus-pane.py`. A missing dependency is a structured operational error.

### 2. Feed the filtered match set to fzf

Convert each existing `MatchRecord` into a safe TSV row:

1. hidden, bounded route token: URL-safe base64 JSON containing only schema version, authoritative socket, session/workspace/tab/pane IDs, source, capture-relative line number, and status (never raw match text/cwd in process argv);
2. compact coordinate/status such as `[default/wP/wP:t2/wP:p3 L42 working]`;
3. sanitized matched line.

Strip C0/C1 controls from visible fields; tabs/newlines must never corrupt the row. Invoke fzf with a tab delimiter, `--with-nth=2..`, `--nth=2..`, bordered full-height layout, stable tiebreaking, source-aware prompt/header, and right-side wrapped preview. The route token stays hidden and unsearchable.

Use `--print-query` plus `--expect=alt-s,alt-v` in an explicit loop:

- **Enter**: focus/attach the selected route.
- **Alt+S**: rerun the same `herdr-grep` pattern against `recent-unwrapped`, then reopen fzf with its refinement query preserved.
- **Alt+V**: rerun against `visible` and preserve the fzf query.
- **Esc/no selected match**: quiet success.
- Unexpected fzf/focus failure: concise diagnostic and nonzero exit.

This is not `change:reload`: pane scanning occurs once per explicit source mode, never on every keystroke.

Honor the existing scan contract:

- complete match set: normal picker;
- clean no-match: exit 1 without launching fzf;
- partial scan with usable matches: keep them selectable and show an incomplete-scan header with error count/first diagnostic;
- partial/fatal scan without usable matches: render normal errors and exit 2.

### 3. Add a reusable route/focus helper

Create `dot_config/herdr/executable_focus-pane.py`, deployed as `~/.config/herdr/focus-pane.py`.

Interface:

```text
focus-pane.py --route-token BASE64_JSON
focus-pane.py --preview-route-token BASE64_JSON
focus-pane.py --socket-path SOCKET --workspace-id WS --tab-id TAB --pane-id PANE
```

Exit 0 only after exact final focus verification; exit 1 for stale targets/Herdr/topology/runtime failures; exit 2 for invalid arguments/token. Print nothing on successful focus and one concise `focus-pane:` diagnostic on failure. Every Herdr subprocess receives a copied environment with the route's `HERDR_SOCKET_PATH`; never infer routing from ambient state, session name, or ID structure.

Exact-focus algorithm:

1. `pane get TARGET` before mutation; require exact pane/workspace/tab coordinates.
2. Probe `agent get TARGET`:
   - agent pane: `agent focus TARGET`, then verify with `pane layout.focused_pane_id`;
   - `agent_not_found`: use generic pane navigation;
   - any other error: fail.
3. For an ordinary pane, validate `pane layout --pane TARGET`: matching workspace/tab, unique pane IDs, target membership, maximum 128 panes.
4. Focus workspace then tab and reread layout. If `focused_pane_id` is already the target, verify and finish.
5. Otherwise run deterministic BFS over `left`, `right`, `up`, `down` using `pane neighbor --pane NODE --direction DIR`. Boundary responses that return the origin pane are non-edges; accept only panes in the validated layout.
6. Before every movement, recheck the expected neighbor, then run `pane focus --direction DIR --pane NODE` and require the new layout's `focused_pane_id` to be the planned neighbor.
7. Permit one bounded replan for a focus/topology race; a second race fails closed.
8. Finish by requiring `workspace get.focused == true`, `workspace.active_tab_id == TARGET_TAB`, `tab get.focused == true`, and target-layout `focused_pane_id == TARGET` (`pane current` identifies the caller pane, not the server's new focus).

Failure after partial movement is reported honestly; Herdr provides no atomic focus transaction.

### 4. Preview selected matches

`focus-pane.py --preview-route-token` decodes the same route and prints:

- stored session/workspace/tab/pane, source, capture-relative line, and status;
- no raw matched line or cwd in the route token; the fzf result row already shows the match;
- a clearly labeled live pane snapshot read through the route socket:

```text
HERDR_SOCKET_PATH=<socket> herdr pane read <pane> --source visible --format text
```

A disappeared pane becomes preview text, not an fzf crash. Do not promise exact scroll positioning: the stored line number belongs to the earlier capture and can drift.

`herdr-grep --pick` points fzf preview at this helper using the hidden route token.

### 5. Focus versus attach semantics

After fzf selection:

- **Inside Herdr** (`HERDR_ENV`/ambient socket): require the selected socket to match the current socket, invoke the focus helper, and exit so the temporary command pane closes. If a user explicitly requested cross-session results inside Herdr, pre-focus may be possible but attach is not; fail with the detach/attach instruction rather than nesting.
- **Outside Herdr**: invoke the focus helper through the selected socket, then attach to the selected session—bare `herdr` for `default`, `herdr session attach NAME` for named sessions. This mirrors `dot_config/shell/24_herdr.sh::_herdr_attach_if_outside` and `hhere` behavior.

The default no-session picker therefore works naturally in both contexts; `--all-sessions --pick` is primarily an outside-Herdr workflow.

### 6. Add the Herdr keybinding

Edit `.chezmoitemplates/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+f"
type = "pane"
command = "~/.dotfiles/bin/herdr-grep --pick"
description = "search pane content and jump (fzf)"
```

`prefix+alt+f` is valid Herdr syntax (the upstream/default config documents `prefix+alt+g`), mnemonic for find, currently unbound, and avoids the existing `prefix+f` fleet picker.

### 7. Update completions and offline tests

Update both existing completion files to advertise `--pick`:

- `dot_config/zsh/tools/59_herdr_grep_completion.zsh`
- `dot_config/bash/59_herdr_grep_completion.bash`

Extend `tests/unit/herdr_grep.bats` for `--pick` parsing/dependencies/result handling/fzf argv and completion agreement. Add `tests/unit/herdr_focus_pane.bats` with a stateful fake Herdr backend.

Picker coverage:

- no-pattern TTY prompt and non-TTY usage failure;
- fzf rows/token/control sanitization;
- Enter/Esc/no-match parsing;
- Alt+S/Alt+V source reruns with query preservation;
- partial/fatal scan handling;
- preview/focus helper invocation;
- inside same-session focus, inside cross-session refusal, outside default/named attach;
- missing fzf/helper and attach failures.

Focus-helper coverage:

- agent direct focus and `agent_not_found` fallback;
- one-pane, horizontal/vertical, nested multi-hop layouts;
- deterministic BFS, cycles/boundaries, stale/moved panes;
- malformed/duplicate/out-of-layout responses;
- workspace/tab failures, one successful replan, retry exhaustion;
- final exact verification and selected-socket enforcement;
- preview routing and disappeared-pane behavior.

### 8. Update documentation mirrors

Update `docs/tools/herdr.md` and `docs/tools/herdr.zh-TW.md` in the content-search, feasibility, keybinding, and Television/fzf sections. Document:

- `herdr-grep --pick PATTERN` pipeline;
- `prefix+Alt+F` with interactive pattern prompt;
- Alt+S/Alt+V source switching;
- exact agent/ordinary-pane jump semantics;
- inside focus versus outside attach behavior;
- cross-session restriction while already attached;
- preview/capture line drift and partial-scan warnings;
- why fzf, not a TV channel.

Update `README.md`, `docs/shells/aliases.md`, `docs/zsh/zsh-completions.md` as needed for the new flag/behavior, and `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` for agent discoverability. No new MkDocs nav entry or PATH executable is needed.

## Verification

1. Compile both Python sources without leaving `__pycache__`; run zsh/bash completion syntax checks.
2. Run updated `herdr_grep.bats`, new `herdr_focus_pane.bats`, then full Bats; distinguish known repository baseline failures by test name.
3. Render `herdr-grep`, `focus-pane.py`, and Herdr config with `chezmoi cat`; verify target paths.
4. Apply only those Herdr targets for live validation, preserving unrelated working-tree changes.
5. Run `herdr server reload-config`; require applied status and empty diagnostics so `prefix+alt+f` cannot silently invalidate the keys table.
6. Headlessly validate fzf row generation/token decode/preview and complete/partial/no-match behavior.
7. If a TTY is available, test `prefix+Alt+F`, agent and ordinary split-pane exact jumps, Alt+S/Alt+V query preservation, quiet Esc, and an outside-shell `--all-sessions --pick` attach. If unavailable, report the skipped interactive checks explicitly.
8. Run targeted pre-commit, strict MkDocs against the known warning baseline, `git diff --check`, and `chezmoi diff`.
9. Leave the new feature uncommitted unless the user separately asks for another commit; preserve the five unrelated old SpecStory modifications.

## References

- [Herdr keyboard syntax](https://herdr.dev/docs/keyboard/)
- [Herdr config reference](https://herdr.dev/docs/config-reference/)
