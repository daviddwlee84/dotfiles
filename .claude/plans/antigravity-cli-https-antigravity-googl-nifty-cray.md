# Add Antigravity CLI to the coding-agents stack

## Context

Google is transitioning **Gemini CLI → Antigravity CLI** for consumer tiers. Antigravity
CLI (Go-based, command surface `agy`, Google Sign-In + system keyring) went GA
2026-05-19; **Gemini CLI stops serving free / AI Pro / Ultra tiers on 2026-06-18**
(Enterprise/Code-Assist unaffected). The user has a **Gemini Pro** subscription, so the
free-tier rate-limit horror stories (7-day lockouts) are less of a concern for them.

This repo already installs the Antigravity **IDE** (Homebrew cask, gated on
`installAiDesktopApps`) and **Gemini CLI** (ansible `coding_agents` role), but Gemini CLI
was never wired into the AICAP agent stack. Goal now: **add the Antigravity CLI** to the
`coding_agents` role and **register it in the AICAP agent stack, slotted just before
`cursor-agent`** in the autodetect priority, then verify the one-shot ("one-liner")
invocation actually works. **Keep Gemini CLI as-is** for now; revisit its removal later
as the Gemini-CLI deprecation lands.

### Phase B findings (probed 2026-05-20 — RESOLVED)

- **The real agentic CLI is v1.0.0**, separate from the IDE. Installer (`install.sh`) places
  a flat Go binary at `~/.local/bin/agy`, checksum-verified, no sudo.
- **One-shot form:** `agy -p "<prompt>"` (`--print`) — clean non-interactive print to stdout.
  Claude-Code-like: `-c/--continue`, `--conversation`, `--dangerously-skip-permissions`,
  `--sandbox`, `--print-timeout 5m`.
- **No `--model` flag** — model selection is account/config-based, NOT a CLI arg. So there is
  **no `AICAP_AGYC_MODEL`**; the agent is wired model-less (documented exception to the
  "add AICAP_<AGENT>_MODEL" rule).
- **Name collision:** Google ships TWO tools named `agy`. The Antigravity **IDE** symlinks
  `agy` AND `antigravity` → a VS Code-fork **editor launcher** (no agent). The user's
  untracked `~/.zshrc.adhoc:20` prepends `~/.antigravity/antigravity/bin` to PATH (pos 1),
  so bare `agy` resolves to the editor, shadowing the CLI at `~/.local/bin` (pos 15).
- **`agy install` mutates shell profiles** (PATH append + alias *purge*); has
  `--skip-path --skip-aliases` to bypass.

### Resolution (user-approved)

- **Token = `agyc`** (no collision — IDE has no `agyc`). Ansible creates a real symlink
  `~/.local/bin/agyc → agy`, so `command -v agyc` / `shutil.which("agyc")` resolve correctly
  with **no special-casing** in autodetect or the 4 consumers. Invocation: `agyc -p "<prompt>"`.
- **Install = binary only, skip shell mutation** (user choice): reuse `install.sh`'s robust
  download/checksum/musl logic but neutralize its `agy install` handoff to run with
  `--skip-path --skip-aliases` (repo already has `~/.local/bin` on PATH; PATH is chezmoi-managed).
- **Convenience aliases** (interactive UX, the editor one guarded by file existence):
  `antigravity-cli → agyc`, `agy-ide → ~/.antigravity/antigravity/bin/agy`.
- **Temporary / keep-tracking:** the `agy` name overload is a Google-side collision; revisit
  if a cleaner upstream story emerges. Log to `TODO.md`.

## Phase A — Install via ansible (concrete, no unknowns)

**File:** `dot_ansible/roles/coding_agents/tasks/main.yml` — add a new `# === Antigravity CLI ===`
block, mirroring the Gemini block at lines 243–304, but using the official curl installer
(no confirmed brew formula). Install-only per repo invariant (`creates:`/`which` guard,
never `state: latest`).

```yaml
# === Antigravity CLI ===
# Replacement for Gemini CLI on consumer tiers (GA 2026-05-19). Official installer
# is a curl script; no brew formula confirmed. Install-only — guarded by `which`.

- name: Check if Antigravity CLI is installed
  ansible.builtin.command: which agy        # confirm binary name in Phase B
  register: agy_check
  changed_when: false
  failed_when: false

- name: Install Antigravity CLI (macOS + Linux, curl installer)
  when: agy_check.rc != 0
  ansible.builtin.shell: |
    set -euo pipefail
    curl -fsSL https://antigravity.google/cli/install.sh | bash
  args:
    executable: /bin/bash
    creates: "{{ ansible_facts['env']['HOME'] }}/.local/bin/agy"   # confirm install path in Phase B
  changed_when: true
```

Open items to confirm in Phase B (do not guess in the committed task): exact binary
name(s), the `creates:` install path, whether the installer honors a non-interactive pipe,
and whether macOS needs Rosetta/keyring entitlements.

**Mirror update:** `README.md` "What You Get" / coding-agents list (per CLAUDE.md cross-file rule).

## Phase B — Probe the one-shot invocation (the "測試一下 one-liner" step)

Run **on a machine after Phase A applies** — this is also the CLAUDE.md "validate with the
app" hard rule. Capture exact output to fill the `<AGYBIN>` / `<AGY ONESHOT>` placeholders:

```sh
command -v agy agy-agent antigravity   # which binary(ies) actually land on PATH
agy --help 2>&1 | head -40
agy-agent --help 2>&1 | head -40       # if it exists
# Auth once (interactive, browser): follow whatever `agy` login flow prints.
# Then test a clean one-shot that prints reply to stdout (NOT a TUI):
<AGYBIN> <AGY ONESHOT> "say hello in one word"
# Confirm: prints to stdout, exits 0, no TUI takeover, model flag form (-m / --model / none).
```

**Decision gate:** if no clean headless one-shot exists (only an interactive TUI / editor
launcher), **stop before Phase C** and report — Antigravity would not fit the AICAP
one-shot contract, and we'd instead document it as IDE-launcher-only (or route via the
existing `http` agent against a Google endpoint). Surface this to the user rather than
forcing a broken wiring.

## Phase C — Wire into the AICAP stack (only if Phase B confirms a clean one-shot)

The AICAP SSOT has **five** sync points (CLAUDE.md "AI agent autodetect" rule). Token =
`<AGYBIN>` everywhere it's probed/dispatched; human-readable env var =
`AICAP_ANTIGRAVITY_MODEL` (precedent: binary `cursor-agent` ↔ var `AICAP_CURSOR_MODEL`).
Default the model **empty** so the CLI picks its own default (robust if a model ID is
retired) — matches `codex`/`cursor-agent`.

1. **SSOT** — `dot_config/shell/04_ai_agents.sh`
   - Priority (line 33): `opencode claude codex <AGYBIN> cursor-agent` (insert **before** `cursor-agent`).
   - Add `: "${AICAP_ANTIGRAVITY_MODEL:=}"` near the other pins (with a comment: Gemini-Pro-backed).
   - Add `AICAP_ANTIGRAVITY_MODEL` to the `export` list (lines 56–59).

2. **Shell invoke** — `dot_config/shell/04_ai_capture.sh`
   - New `case` arm in `_aiagent_invoke` (model the `cursor-agent` arm at lines 216–229:
     conditional `--model`/`-m`, spinner start/stop, `return $rc`), running
     `<AGYBIN> <AGY ONESHOT> [model flag] "$prompt"`.
   - Update the `*)` "supported:" error string (line 282) and the `aifix`/`air` help text
     to list the new agent.

3. **Shell run shortcut** — `dot_config/shell/05_ai_run.sh`
   - Add an `agr()` wrapper (mirror `cur()` at lines 73–81) → `<AGYBIN> <AGY ONESHOT> [model flag] "$@"`.
   - Add `agent|ag` case to `air()`'s dispatch (line 147–165) and to its `-a AGENT` help list.

4. **Four Python consumers** — add the `_env_or_ssot("AICAP_ANTIGRAVITY_MODEL", "")` decl,
   the `AGENT_CONFIG` `"<AGYBIN>": {"base": [...]}` entry, and the model-label dict line in each:
   - `dot_config/tmux/executable_tmux-session-summary.py` (decls ~149, AGENT_CONFIG ~193, label ~558)
   - `scripts/aiblock.py` (decls ~104, AGENT_CONFIG ~135, label ~286)
   - `dot_dotfiles/bin/executable_pqsum` (decls ~106, AGENT_CONFIG ~123, label ~670)
   - `scripts/fleet/exec.py` (decls ~109, AGENT_CONFIG ~126, label ~414)
   > Note: `executable_pqsum:69` says "three consumers" — stale; there are four. Optionally fix that comment.

5. **Docs** — `docs/shells/aliases.md`: add `agr` row (AI Run section) + mention the new
   agent in the AI Capture priority list. `docs/zsh/zsh-completions.md`: add `<AGYBIN>` to
   Category D (no completion support) unless Phase B shows a `--completion` flag.

### Known tradeoff (flag, don't block)

CLAUDE.md warns the four-consumer fan-out has "reached the pain threshold" and that the
next AI-tooling change "should land the `scripts/aisum/__init__.py` refactor before adding
more callsites." This plan adds a 5th callsite manually (smallest diff, matches user
intent). Recommend logging the extraction refactor to `TODO.md` rather than expanding scope
here — unless the user wants the refactor done first.

## Verification (end-to-end)

1. **Ansible:** narrowest practical run of the `coding_agents` role (check-mode first, then
   real) on one host; confirm `which agy` resolves and `agy` is install-only/idempotent on
   re-run. (`--syntax-check` is only a first pass per repo invariant.)
2. **Phase B probe** output pasted into the final report — the literal one-shot command + its stdout.
3. **Shell:** `source ~/.config/shell/04_ai_agents.sh` then
   `air -a <AGYBIN> "one word hello"` and `agr "one word hello"` → text reply, exit 0.
   `air -h` shows the new agent; autodetect picks it ahead of `cursor-agent` when only those two are present.
4. **Python parity:** run each of the 4 consumers' agent-detection path (or import-and-print
   `AGENT_CONFIG`) to confirm the new key parses and the SSOT regex picks up the new pin.
5. **shellcheck** clean on the two edited `dot_config/shell/*.sh` files (repo lints these at error severity).

## Out of scope (per user)

- Removing/deprecating the Gemini CLI ansible task — deferred until Gemini-CLI deprecation
  actually bites; revisit then.
- The `scripts/aisum/__init__.py` consumer-extraction refactor — log to `TODO.md`.
