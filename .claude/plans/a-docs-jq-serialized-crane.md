# Plan: Make `modify_*` scripts tolerant of cold-start missing tools (Option A)

## Context

A user (`yzhang@idc-server104`, `centos_server` profile, `noRoot=true`) ran `chezmoi update --init` on a fresh box and hit:

```
[SUCCESS] Bootstrap complete!
/tmp/934409313..skill-lock.json: line 59: jq: command not found
chezmoi: .agents/.skill-lock.json: exit status 127
```

### Why this is a real chicken-and-egg

`chezmoi apply` runs in this order:

1. `run_once_before_*` scripts → `00_bootstrap.sh.tmpl` installs **uv, mise, ansible-core** only. **Does not install `jq` (or `ripgrep`, `fd`, `python3`, etc.)**.
2. **File-application phase** → executes every `modify_*` script. Several of them (`dot_agents/modify_dot_skill-lock.json.tmpl:58`, etc.) hard-call `jq` with `set -eu` and no `command -v` guard. **Crashes here on a fresh machine.**
3. `run_onchange_after_20_ansible_roles.sh.tmpl` → `base` role would install `jq` (apt/yum/brew + noRoot GitHub-release fallback at `dot_ansible/roles/base/tasks/main.yml:248-275`). **Never reached** because step 2 aborted apply.

Result: every fresh machine where `jq` isn't already installed fails the *first* apply. Workaround currently requires manually `curl`-installing jq into `~/.local/bin/`.

### Audit — which `modify_*` scripts are at risk

| File | Calls | Has graceful-skip? |
|---|---|---|
| `dot_agents/modify_dot_skill-lock.json.tmpl` | `jq` | ❌ |
| `dot_claude/modify_keybindings.json` | `jq` | ❌ |
| `dot_claude/modify_settings.json` | `jq` | ❌ |
| `dot_config/opencode/modify_opencode.json.tmpl` | `jq` | ❌ |
| `dot_config/opencode/modify_tui.json.tmpl` | `jq` | ❌ |
| `dot_cursor/modify_cli-config.json.tmpl` | `jq` | ❌ |
| `.chezmoitemplates/editor/modify.sh` (covers 6 wrappers: Code/Cursor/Antigravity × Linux+macOS) | `python3` + `jq` | ❌ |
| `dot_codex/modify_config.toml.tmpl` | `uv`/`python3` | ✅ (`:47-55`) |
| `dot_config/docker/modify_daemon.json.tmpl` | `jq` | ✅ (`:28-31`) |
| `dot_docker/modify_config.json.tmpl` | `jq` | ✅ (`:19-21`) |

Existing graceful-skip pattern, used as the reference implementation: `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl:32-35`.

### Intended outcome

- First `chezmoi apply` on a fresh box completes successfully even without jq/python3.
- Each affected `modify_*` script falls back to **pass-through** (live file unchanged on stdin → unchanged on stdout) and prints a stderr warning telling the user to re-apply once `base` ansible role finishes installing jq.
- After ansible installs jq, the next `chezmoi apply` does the real merge — idempotent.
- Document the contract so future `modify_*` scripts inherit the rule.

---

## Approach (Option A — graceful-skip)

### Canonical fallback snippet (mirror existing patterns)

For pure-jq scripts:

```sh
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "modify_<file>: jq not found; passing live file through unchanged. Re-run \`chezmoi apply\` after the base ansible role installs jq." >&2
  printf '%s' "$base"
  exit 0
fi
```

For `editor/modify.sh` (needs both python3 and jq, with uv→python3 fallback chain like `dot_codex/modify_config.toml.tmpl:47-55`):

```sh
# Pick a python3 (uv-managed if available, else system python3).
if command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD="python3"
elif command -v uv >/dev/null 2>&1; then
  PYTHON_CMD="uv run --no-project --quiet --python >=3.11 python"
else
  printf '%s\n' "editor/modify.sh: neither python3 nor uv found; passing live file through unchanged. Re-run \`chezmoi apply\` after ansible bootstrap." >&2
  printf '%s' "$base"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "editor/modify.sh: jq not found; passing live file through unchanged. Re-run \`chezmoi apply\` after the base ansible role installs jq." >&2
  printf '%s' "$base"
  exit 0
fi
```

The pass-through is **always** safe: chezmoi sees stdout matches the live file → no-op for that target → apply continues.

---

## File changes (7 fix-points)

| # | File | Insert point | Action |
|---|---|---|---|
| 1 | `dot_agents/modify_dot_skill-lock.json.tmpl` | After `[ -z "$base" ] && base='{"version":3,"skills":{}}'` (line 48), before `printf '%s' "$base" \| jq …` (line 58) | Add jq-guard pass-through |
| 2 | `dot_claude/modify_keybindings.json` | Before the `\| jq --argjson overlay` pipe at line 67 | Add jq-guard |
| 3 | `dot_claude/modify_settings.json` | Before `printf '%s' "$base" \| jq --argjson overlay` at line 86 | Add jq-guard |
| 4 | `dot_config/opencode/modify_opencode.json.tmpl` | Before line 30 jq pipe | Add jq-guard |
| 5 | `dot_config/opencode/modify_tui.json.tmpl` | Before line 34 jq pipe | Add jq-guard |
| 6 | `dot_cursor/modify_cli-config.json.tmpl` | Before line 26 jq pipe | Add jq-guard |
| 7 | `.chezmoitemplates/editor/modify.sh` | Between line 42 (`base=…`) and line 44 (`python3 -c …`) | Add **both** python3-fallback chain and jq-guard. Replace the bare `python3` call at line 44 with `$PYTHON_CMD` (eval-form so the `uv run ...` multi-arg case works) |

Per-file comment update: where the existing `# Requires: jq …` comment exists (e.g. `dot_agents/modify_dot_skill-lock.json.tmpl:22`, `.chezmoitemplates/editor/modify.sh:32-33`), append a sentence like `(missing-jq path: live file is passed through unchanged; re-run apply once ansible installs jq)` so the next reader doesn't think the guard is dead code.

---

## Documentation changes

### New: `pitfalls/modify-script-jq-bootstrap-cycle.md`

Symptom-titled per the pitfall convention (verbatim error message in body):

```
chezmoi: .agents/.skill-lock.json: exit status 127
/tmp/<random>..skill-lock.json: line NN: jq: command not found
```

Sections:

1. **Symptom** — the exact stderr from the user's run, with `jq: command not found` as the grep target.
2. **Root cause** — chezmoi's apply order (`run_once_before` → file apply → `run_onchange_after`); modify_ scripts execute in the file-apply phase, BEFORE ansible roles in `run_onchange_after_20_ansible_roles.sh.tmpl`. Bootstrap installs uv/mise/ansible only, not jq.
3. **Audit table** — same 10-row table from "Context" above, so a maintainer adding a new modify_ script sees the contract.
4. **Fix** — describe the graceful-skip pattern; link to `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl:32-35` as the reference.
5. **Workaround for users hit by an unfixed version** — manual `curl ~/.local/bin/jq` snippet (mirrors `base/tasks/main.yml:248-275` user-level fallback) and a follow-up `chezmoi apply`.
6. **Related** — cross-link `pitfalls/centos7-noroot.md` (which already mentions jq is missing on noRoot CentOS) and `docs/tools/chezmoi-prefixes.md` (the new contract section below).

### Extend: `docs/tools/chezmoi-prefixes.md`

Add a new subsection under the `modify_` heading (around line 69-74), titled:

> **Bootstrap-order contract: `modify_` scripts MUST tolerate missing tools**

Body:
- chezmoi apply order: `run_once_before_*` → **file-apply (this is where modify_ runs)** → `run_onchange_after_*`.
- Bootstrap (`run_once_before_00_bootstrap.sh.tmpl`) only guarantees `uv`, `mise`, `ansible-core`, `curl`, `git`, `bash`/`sh`, basic POSIX. Anything else (jq, python3, ripgrep, fd, …) is installed by ansible roles in `run_onchange_after_20_ansible_roles.sh.tmpl` — **after** modify_ scripts have run.
- Therefore: any `modify_` script that invokes a tool from the post-bootstrap set MUST `command -v` guard and pass-through `"$base"` if missing.
- Reference implementations (link to the three good citizens): `dot_codex/modify_config.toml.tmpl:47-55`, `dot_config/docker/modify_daemon.json.tmpl:28-31`, `dot_docker/modify_config.json.tmpl:19-21`.
- Cross-link the new pitfall.

(No CLAUDE.md update — keeps headroom; the chezmoi-prefixes doc is already linked from `CLAUDE.md` → "modify_ and create_ prefix semantics" → `[docs/tools/chezmoi-prefixes.md → Case studies in this repo]`, so the contract is reachable.)

---

## Verification

### Local sanity (no fresh-box needed)

1. **Pass-through correctness** — for each of the 7 fix-points, simulate the missing-tool case:
   ```sh
   PATH=/usr/bin:/bin sh -c 'unset -f jq; echo "{\"existing\":1}" | bash dot_agents/modify_dot_skill-lock.json.tmpl 2>err.log'
   ```
   Expect: stdout = `{"existing":1}` (unchanged), stderr contains `jq not found` warning, exit 0.

2. **Normal path still works** — with jq on PATH:
   ```sh
   chezmoi execute-template < dot_agents/modify_dot_skill-lock.json.tmpl > rendered.sh
   echo '{"version":3,"skills":{"existing":{"source":"x","sourceType":"github","sourceUrl":"y","skillPath":"z"}}}' | sh rendered.sh
   ```
   Expect: merged output containing both `existing` and the managed entries.

3. **`chezmoi diff`** on the local MacBook (jq present) — should produce zero diff for all 7 affected targets vs. before (i.e. graceful-skip code is dead-code on a healthy box).

### Cold-start smoke test (the actual scenario)

Reproduce on a fresh container or VM:

```sh
docker run --rm -it ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq curl git zsh sudo locales >/dev/null
  useradd -m -s /bin/zsh test && echo "test ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
  su - test -c "
    sh -c \"\$(curl -fsLS get.chezmoi.io)\" -- init --apply --branch <feature-branch> daviddwlee84
    echo \"---exit=\$?---\"
    command -v jq && echo jq-now-present
  "
'
```

Expect:
- Apply completes with exit 0 (or only ansible-related warnings).
- `~/.agents/.skill-lock.json` exists (possibly seeded with empty `{"version":3,"skills":{}}`).
- After bootstrap, `jq` is on PATH (ansible base role installed it).
- Running `chezmoi apply` a SECOND time produces the real merge.

### CentOS 7 noRoot sanity (the original report scenario)

`yzhang@idc-server104` re-runs `chezmoi update --init`:
- First apply: completes, with stderr warnings on the 7 modify_ scripts (jq missing).
- ansible base role downloads jq to `~/.local/bin/jq` via GitHub-release fallback.
- Second apply: real merges happen, `~/.agents/.skill-lock.json` populated correctly.

### Pre-commit hooks

Run `just check-secrets` and the standard pre-commit hooks on the diff. The new pitfall file is under `pitfalls/` (auto-redacted prefix per `scripts/redact_secrets.py` → `DEFAULT_PATHS`). Should pass cleanly.

### MkDocs strict build (because we touched a `docs/` file)

```sh
uv run mkdocs build --strict
```

Should pass — only adding a subsection to an existing tracked page (`docs/tools/chezmoi-prefixes.md`); no new page → no `mkdocs.yml` nav edit needed. The new `pitfalls/modify-script-jq-bootstrap-cycle.md` is referenced as an absolute GitHub URL, not added to nav (per the "What does NOT belong in `docs/`" rule).
