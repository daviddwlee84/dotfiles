# Add `tokens` (tokens.ci) to the coding_agents role

## Context

`tokens` (github.com/missuo/tokens, MIT, Rust; fork of junhoyeo/tokscale) tracks AI
coding-assistant token usage and can submit it to the tokens.ci leaderboard. User wants
it in the agent toolset on both macOS and Linux.

**Why the Linux install failed:** `https://tokens.ci/install.sh` is a *bash* script
(`set -euo pipefail` on line 18) but the docs say `| sh`. On Ubuntu `sh` is dash →
`set: Illegal option -o pipefail`. Manual workaround right now:
`curl -fsSL https://tokens.ci/install.sh | bash` (or `TOKENS_NO_SERVICE=1 … | bash`
to skip writing the systemd user unit). We won't use the curl installer in ansible:
it also writes `~/.config/systemd/user/tokens.service`, which we don't want managed.

Upstream facts (v27.1.1): release assets for `{x86_64,aarch64}-unknown-linux-{gnu,musl}`
+ macOS; `<asset>.sha256` sidecars; Homebrew formula `owo-network/brew/tokens` (third-party
tap → Homebrew ≥6 trust gate; formula covers Linuxbrew too, using the **gnu** builds).

**Decision (user):** install the binary only. `tokens login` + `tokens serve` /
`brew services start tokens` / systemd unit stay manual and documented — no auto-upload
from fleet hosts.

## Changes

### 1. `dot_ansible/roles/coding_agents/tasks/main.yml` — new `# === tokens ===` block
Model on the `# === CodexBar ===` Linux block (~line 798) but simpler:

- **macOS:** probe brew by output; `homebrew_tap owo-network/brew` → `brew tap-info` /
  `brew trust owo-network/brew` when `Untrusted` (same shape as the steipete trust tasks,
  see `pitfalls/homebrew-6-refuses-untrusted-tap-formula.md`) → `homebrew: owo-network/brew/tokens`.
- **Linux (Debian/RedHat):** guard `which tokens` (+ `~/.local/bin/tokens` stat).
  - Install from GitHub release, **musl asset** (static → no glibc floor, no third-party
    tap trust): `uri` latest release → `get_url` `tokens-<tag>-<arch>-unknown-linux-musl.tar.gz`
    with `checksum: sha256:<url>.sha256` (verify sidecar format is `hash  filename`; if not,
    fetch + parse like the codexbar note) → `unarchive` → copy to `~/.local/bin/tokens` 0755.
  - Arch from `target_architecture` (x86_64/aarch64 mapping as codexbar does); skip with a
    debug msg on other arches.
  - Rationale vs Linuxbrew: avoids the codexbar-style glibc trap (formula ships gnu build)
    and the tap-trust step. Implementation step: `objdump -T` the gnu binary to record its
    GLIBC floor in the comment.
- No service / login tasks.

### 2. `dot_config/docs/tools/tool-catalog.toml`
New `[[tool]] id = "tokens"`, category "AI / Coding Agents", role `coding_agents`,
`mac = "brew \`owo-network/brew\` (trusted tap)"`, `linux = "GitHub release (static musl)"`,
`docs = "docs/tools/tokens.md"`. Then `just gen-tool-index`.

### 3. Docs
- `docs/tools/tokens.md` (+ `.zh-TW.md` per repo convention) — what it is, install paths,
  the `| sh` vs `| bash` pitfall, manual next steps (`tokens login`; Linux:
  `systemctl --user` unit snippet or `TOKENS_NO_SERVICE`; macOS: `brew services start tokens`),
  privacy note (serve uploads usage). Nav entry in `mkdocs.yml`.
- `pitfalls/tokens-install-sh-illegal-option-pipefail.md` — symptom verbatim:
  `sh: 17: set: Illegal option -o pipefail`.
- `README.md` Coding Agents bullet: add `tokens`.
- `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`: mention `tokens` in the agent tool list.
- Upgrade story: brew covered by `just upgrade-brew`; Linux release install — check
  `docs/this_repo/upgrades.md` / `scripts/upgrade_tools.sh` for how codexbar's release
  fallback is upgraded and mirror it (or note "re-run with file removed" if none exists).

## Verification
- `ansible-playbook` narrow run of `coding_agents` (check mode, then real) on this Linux host
  → `tokens --version` from `~/.local/bin`; re-run is idempotent (no `changed`).
- `uv run pytest tests/unit/test_tool_catalog.py`; `just gen-tool-index` produces no extra drift.
- `just docs-build`.
- macOS path: can't run here — state so in the report, or run via fleet on a mac host if
  available.
