# Fix sesh-opened folder shell cwd (tmuxp append ignores session-level start_directory)

## Context

When the user opens a repo via the sesh wildcard (`pattern = "/Volumes/Data/Program/*/*"` in [`dot_config/sesh/sesh.toml:111-113`](../../dot_config/sesh/sesh.toml)), the session appears correct at the session level but each window's pane is created at `$HOME` instead of the matched path.

Runtime evidence (session `Personal/agent-skills`):

```
session_path:              /Volumes/Data/Program/Personal/agent-skills   ✓
editor pane_current_path:  /Users/daviddwlee84                           ✗  (nvim launched from HOME)
git    pane_current_path:  /Users/daviddwlee84                           ✗  (lazygit launched from HOME)
shell  pane_current_path:  /Volumes/Data/Program/Personal/agent-skills   (only because user manually cd'd)
```

### Root cause (verified in tmuxp source)

[`tmuxp/workspace/builder.py:388`](../../../../.local/share/uv/tools/tmuxp/lib/python3.13/site-packages/tmuxp/workspace/builder.py) in `iter_create_windows`:

```python
start_directory = window_config.get("start_directory", None)
# ... falls back to panes[0].start_directory, but NOT session_config.start_directory
window = session.new_window(..., start_directory=start_directory, ...)
```

Session-level `start_directory` is only consulted when tmuxp creates a NEW session (`build()` lines 250, 296). In **append mode** (`tmuxp load -a`), tmuxp skips session creation and goes straight to `iter_create_windows`, where session-level `start_directory` is never read. With `start_directory=None`, libtmux omits `-c` on `tmux new-window`, and tmux falls back to the server's cwd (the shell that launched the tmux server — typically `$HOME`).

So our [`dot_config/tmuxp/project.yaml:22`](../../dot_config/tmuxp/project.yaml)

```yaml
start_directory: ${start_directory:-.}
```

is **silently dead code in append mode** — which is the only way sesh invokes it.

Sesh itself is fine: it creates the session with `tmux new-session -c <matched_path>` (hence `session_path` is correct). The broken hop is tmuxp → new-window.

### Intended outcome

`sesh connect /Volumes/Data/Program/Personal/agent-skills` yields all three windows (editor/shell/git) rooted at the project path. `nvim` and `lazygit` launch against the repo. No manual `cd` needed.

## Change

### 1. `dot_config/tmuxp/project.yaml` — add window-level `start_directory`

Session-level stays for direct (non-append) invocation; window-level is what tmuxp actually honors in append mode.

```yaml
session_name: project
start_directory: ${start_directory:-.}

windows:
  - window_name: editor
    start_directory: ${start_directory:-.}
    panes:
      - shell_command: nvim

  - window_name: shell
    start_directory: ${start_directory:-.}
    panes:
      - shell_command: ""

  - window_name: git
    start_directory: ${start_directory:-.}
    panes:
      - shell_command: |
          if command -v lazygit >/dev/null 2>&1; then
            lazygit
          else
            git status
          fi
```

Add a short comment above `windows:` noting the duplication is required because `tmuxp load -a` ignores session-level `start_directory` (tmuxp ≥ 1.64, builder.py:388).

### 2. `dot_config/tmuxp/coding-agent.yaml` — same fix

Same bug, same shape (also invoked via `tmuxp load -a` from [`sesh.toml:77`](../../dot_config/sesh/sesh.toml)). Add `start_directory: ${start_directory:-.}` to both the `editor` and `monitor` windows.

`scode` (in [`dot_config/zsh/tools/22_sesh.zsh`](../../dot_config/zsh/tools/22_sesh.zsh)) bypasses tmuxp and composes windows manually, so it's unaffected — no change there.

### 3. `pitfalls/tmuxp-append-ignores-session-start-directory.md` — new pitfall

Qualifies per CLAUDE.md triggers: silent failure (no error, session_path looks right), non-obvious fix (only apparent after reading tmuxp source), >15 min to debug, not googleable by symptom. Title by symptom — something like "panes open at `$HOME` when sesh wildcard + tmuxp `--append` creates a session".

Include:
- Verbatim symptom (`pane_current_path=/Users/...` vs correct `session_path`)
- Exact tmuxp source reference (`builder.py:388`, `iter_create_windows`)
- Red herring ruled out: `session_path` being correct makes this look like a shell-rc problem (zsh `chpwd`, `CDPATH`), not a tmuxp problem
- Fix: window-level `start_directory` duplicates session-level

## Files to modify

| Path | Change |
|------|--------|
| `dot_config/tmuxp/project.yaml` | Add `start_directory: ${start_directory:-.}` to each of 3 windows + brief WHY comment |
| `dot_config/tmuxp/coding-agent.yaml` | Add `start_directory: ${start_directory:-.}` to each of 2 windows |
| `pitfalls/tmuxp-append-ignores-session-start-directory.md` | New file |

No changes needed to `sesh.toml`, `sesh-picker.sh`, `22_sesh.zsh`, or `docs/tools/sesh.md` (the existing sesh.md description is still accurate, just under-specifies the tmuxp quirk — the pitfall file covers that).

## Verification

1. **Kill the stale session** so we re-create it from scratch:
   ```
   tmux kill-session -t "Personal/agent-skills" 2>/dev/null
   ```
2. **Apply** the yaml changes (`chezmoi apply` — or just edit in-place since `dot_config/tmuxp/*.yaml` are plain copies, no templating).
3. **Re-open via sesh**:
   ```
   sesh connect /Volumes/Data/Program/Personal/agent-skills
   ```
4. **Inspect cwd on each window** — expected: all three rows show the project path:
   ```
   tmux list-panes -s -t "Personal/agent-skills" \
       -F '#{window_name}: #{pane_current_path}'
   ```
   Expected:
   ```
   editor: /Volumes/Data/Program/Personal/agent-skills
   shell:  /Volumes/Data/Program/Personal/agent-skills
   git:    /Volumes/Data/Program/Personal/agent-skills
   ```
5. **Spot-check nvim**: in the `editor` window, `:pwd` returns the project path.
6. **Spot-check lazygit**: in the `git` window, it shows this repo's branch/status (not HOME).
7. **Non-append regression**: `cd /tmp && tmuxp load -y ~/.config/tmuxp/project.yaml` (no sesh) should still produce a session rooted at `/tmp` — session-level `${start_directory:-.}` still drives the new session, window-level is redundant but consistent.
8. **Coding-agent sanity**: `sesh connect coding-agent` → `tmux list-panes -s -t coding-agent -F '#{window_name}: #{pane_current_path}'` should NOT show `$HOME` for editor/monitor after the fix (baseline for this session is HOME since it's the legacy session; the fix makes it honor `$start_directory` if set, and `.` = HOME otherwise — same as before for the default call).
