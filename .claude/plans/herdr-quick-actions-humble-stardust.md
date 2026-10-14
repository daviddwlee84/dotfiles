# herdr: open a coding agent from Quick Actions and hotkeys

## Context
You want a fast way to open claude / codex / opencode / `claude-copilot-once` / `codex-copilot-once` from inside herdr, choosing (a) SpecStory recording or a direct run and (b) right split, down split, or new tab. Two things get in the way today. Splitting by hand starts a full zsh (about 0.3s), and then you still type the command. Copilot-once is a shell function in `dot_config/shell/43_copilot_proxy.sh`, so it only exists in a shell that has loaded your full config.

**Menu limits (checked in the herdr-plus source, `action.go`).** The `Translate pane` screen you pointed to has two levels: the Quick Actions list, then one `select`. An `Option` has only `label/value/description/heading`, with no nested options, so a third level isn't possible. `heading` *does* render a dim group title, though. So the plan uses the Translate-pane shape:

- **Level 1** (the Quick Actions list, prefix+y): one action per agent, all named `Agent: …`. Typing `agent` filters to exactly these.
- **Level 2** (`select` with headings): the recording × placement combos, grouped under headings:
  ```
  SpecStory            ← heading
    → Split right
    ↓ Split down
    ⊞ New tab
  Direct               ← heading
    → Split right / ↓ Split down / ⊞ New tab
  ```
  OpenCode has no SpecStory provider, so it shows only the Direct group. The copilot variants map run/off to `--specstory-mode run|off`.

## Design

### 1. Launcher: `dot_config/herdr/executable_agent-open.sh` (new)
- Usage: `agent-open.sh <right|down|tab> <agent> <run|off>`, or `agent-open.sh last`.
- `agent` is checked against an allowlist: `claude codex opencode claude-copilot codex-copilot`. Nothing passed through is ever `eval`'d.
- Source pane is `$HERDR_PLUS_PANE_ID`, falling back to `$HERDR_ACTIVE_PANE_ID` and then `herdr pane current`. The cwd is `$HERDR_PLUS_WORKDIR`, then `$HERDR_ACTIVE_PANE_CWD`.
- Splits use `herdr pane split <pane> --direction right|down --cwd … --focus --env HERDR_AGENT_LAUNCH="<agent> <run|off>"`.
- Tabs use `herdr tab create --cwd … --label <agent> --focus --env HERDR_AGENT_LAUNCH=…`.
- It writes the choice to `~/.cache/herdr/agent-open.last`, which is what `last` reads.
- On failure it calls `herdr notification show`, following the same pattern as `sidecar.sh` and `pane-translate.sh`.

### 2. Fast path in the rc files (top of `dot_zshrc.tmpl` and `dot_bashrc.tmpl`, identical small block)
```sh
if [ -n "${HERDR_AGENT_LAUNCH:-}" ]; then
  _hal=$HERDR_AGENT_LAUNCH; unset HERDR_AGENT_LAUNCH
  "$HOME/.config/herdr/agent-run.sh" $_hal   # child process; env changes don't leak
  unset _hal
fi   # then the normal rc continues → after the agent exits you get a fully loaded shell in the same pane
```
- The block goes in both rc files because the CLAUDE.md rules say both shells always deploy and must not be gated.
- It is placed before the oh-my-zsh, ble.sh and plugin init, so the bash 12-step init order is unaffected.
- `unset` runs first, so nested shells don't re-trigger it.

### 3. Lean runner: `dot_config/herdr/executable_agent-run.sh` (new, bash)
- Sources only what the agent needs:
  - `~/.config/shell/00_exports.sh` (PATH for `~/.local/bin` and `~/.opencode/bin`). A login shell lacks these; I checked.
  - mise PATH via `mise env -s bash`.
  - `~/.shellrc.secrets` and `~/.config/bash/secrets.sh`, if present.
  - `43_copilot_proxy.sh`, only for the copilot agents. Sourcing it on its own works; I checked with `bash --norc`.
- It re-checks the allowlist, then maps the choice to a command:
  - `claude run` → `specstory run claude` (always names the agent explicitly; see pitfall `specstory-run-default-agent-drift`)
  - `claude off` → `claude`; `codex` works the same way
  - `opencode` → `opencode`
  - `claude-copilot run|off` → `claude-copilot-once --specstory-mode run|off`; `codex-copilot` works the same way
- Known gap, to be documented: the zsh-only `~/.config/zsh/secrets.zsh` is not loaded on the fast path.
- `HERDR_AGENT_FULL_RC=1` is an escape hatch. It sends the launcher down the slow path: split with no env, then `herdr pane run` into the fully loaded shell.

### 4. Quick Actions (new files under `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions/`)
- New files: `agent-claude.toml`, `agent-codex.toml`, `agent-opencode.toml`, `agent-claude-copilot.toml`, `agent-codex-copilot.toml`.
- Each one has `type = "select"` and `command = "~/.config/herdr/agent-open.sh {{.Value}}"`.
- Each option value has the form `right claude run`.
- Each file starts with a header comment, in the same style as `translate-pane.toml`.

### 5. Hotkeys (`.chezmoitemplates/herdr/config.toml`, `[[keys.command]]`, `type = "shell"`, which is detached)
| Key | Action |
|---|---|
| `prefix+alt+c` | claude + SpecStory → split right |
| `prefix+alt+x` | codex + SpecStory → split right |
| `prefix+alt+t` | claude + SpecStory → new tab |
| `prefix+alt+r` | repeat last choice (`agent-open.sh last`) |

- These keys are free: the bound `prefix+alt+*` keys are only `1..9`, `a`, `e` and `f`.
- During implementation, verify that `type="shell"` receives `HERDR_ACTIVE_PANE_ID`/`_CWD`. If it doesn't, fall back to `type = "pane"` with a script that exits right away.

### 6. Docs, tests and mirrors
- `docs/tools/herdr.md` and `herdr.zh-TW.md`: add a new § "Open a coding agent" covering the menu, the hotkeys, the fast path and the env gap.
- `docs/shells/keybindings.md`: add rows for the 4 keys.
- `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`: mention the herdr agent launcher and its keys, according to the CLAUDE.md "surfaced to agents" row.
- `tests/unit/herdr_agent_open.bats`: stub `herdr` on PATH in the style of `herdr_pane_translate.bats`, then assert:
  - the split/tab argv
  - allowlist rejection
  - the `last` round-trip
  - the agent-run command mapping, with `specstory`/`claude` stubbed

## Verification
- `bats tests/unit/herdr_agent_open.bats`.
- `chezmoi apply`, then `herdr server reload-config`. That command validates the config with the app itself.
- Manually in herdr:
  - prefix+y → type `agent` → Claude → SpecStory/Split right: the agent appears with no typed command. Quit it and a full shell prompt should follow.
  - Repeat with New tab, and with codex-copilot Direct.
  - Try each of the 4 hotkeys, and check that `prefix+alt+r` repeats the last choice.
- Timing: compare a fast-path split against prefix+v followed by typing `claude`.
- Run `zsh -i -c exit` and `bash -i -c exit` with no env set, to confirm the rc block is a no-op.
