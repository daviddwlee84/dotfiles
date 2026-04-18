# RPi 4 (armhf userland) + carry-over macOS fixes

## Context

The RPi 4 ran `chezmoi update --init` against the latest main and failed in multiple places. Root cause is the classic RPi-4 layout: **64-bit kernel (`uname -m` → aarch64) + 32-bit `armhf` userland**. `target_architecture` is already correctly set to `armv7l` via `dpkg --print-architecture` in `dot_ansible/playbooks/linux.yml:21-27`, and several roles guard on it (`gh`, `glab`, `diffnav`, `glow`, `sesh`, `taplo`, `television` — see `dot_ansible/roles/devtools/tasks/main.yml`). What's missing is the **same guard in three more places**, plus a couple of installers that download from `uname -m` directly and silently produce the wrong arch binary.

Two items from earlier in the session (macOS brew-bundle sudo TTY, coding-agents Claude native installer) are also included so we land them together — user can drop either from scope.

## Problems observed

| # | Where | Symptom | Root cause |
|---|-------|---------|-----------|
| 1 | `mise install` (lazyvim_deps) | `bun-linux-arm.zip` 404 | bun has no armv7l build |
| 2 | `mise install` | `node@lts` compiles from source → link fails `__atomic_load_8` | Node.js 21+ dropped armv7l prebuilts; source build on armhf needs `-latomic` |
| 3 | `mise install` | `ruby@3` ruby-build fails | No armv7l prebuilt; source build chain too heavy for RPi 4 |
| 4 | lazyvim_deps tree-sitter cargo fallback | `bindgen` panics: `Unable to find libclang` | `libclang-dev` not in base packages |
| 5 | devtools git-delta | `git-delta_..._armv7l.deb` 404 | No armv7l release |
| 6 | devtools tldr | npm needed but mise node failed (same as #2) | cascade of #2 |
| 7 | coding_agents Claude Code (Linux) | Downloads `claude-...-linux-arm64`, "cannot execute" under armhf userland | `install.sh` uses kernel `uname -m`; arm64 binary can't run on armhf |
| 8 | *macOS carry-over* brew bundle | `sudo: unable to read password: Input/output error` on google-drive / squirrel / ollama-app | `run_onchange_after_30_brew_bundle.sh.tmpl` lacks the `sudo -v` pre-auth that `20_ansible_roles` got in `c4baaeb` |
| 9 | *macOS carry-over* coding_agents Claude Code | Warning: "Claude Code has switched from npm to native installer" | Role installs via npm; official recommendation is `curl … /install.sh \| bash` |

## Fixes — files to change

### A. lazyvim_deps — `dot_ansible/roles/lazyvim_deps/tasks/main.yml`

**A1.** Before `Install mise global tools`, compute a filtered arg list. Pattern the task after the existing `gh_release_arch` / skip guard (devtools:60-77).

On `target_architecture == "armv7l"`:
- Replace `{{ mise_bin }} install --yes` with an explicit list that excludes `bun`, `ruby`; and pin node to a known-armv7l-prebuilt major (`node@20` is the last LTS with armv7l prebuilts). Do this by passing explicit tool@version pairs instead of reading `~/.config/mise/config.toml`:
  - `{{ mise_bin }} install --yes node@20 rust@latest`
- On all other arches, keep current `{{ mise_bin }} install --yes` (reads config.toml unchanged).

**A2.** `Install tree-sitter-cli via mise npm` — add `when: target_architecture not in ['armv7l','armv6l']` so we don't spend 30 min trying.

**A3.** `Install tree-sitter-cli via cargo (fallback)` (main.yml:245) — before `cargo install`, apt-install `libclang-dev` (guarded by `tags: [sudo]`, skipped on noRoot). Also add the armv7l skip — tree-sitter-cli build is ~9 min on RPi 4 and still fails without libclang.

### B. devtools — `dot_ansible/roles/devtools/tasks/main.yml`

**B1.** `git-delta` block (line 543-591): wrap both the system `.deb` install and the user tarball fallback (line 601-) with `target_architecture in ['x86_64','aarch64','arm64']` guard, mirroring the gh/glab skip pattern. Emit a `"git-delta skipped: no release for {{ target_architecture }}"` debug msg. Update the "Tools skipped on armv7l" table in `CLAUDE.md` to keep the list accurate (delta is already listed there, so just verify).

**B2.** `Install tldr via mise npm (user-level, no sudo)` (line 948): add `target_architecture not in ['armv7l','armv6l']` guard. Current task silently waits 30 min for a mise node build that will never succeed.

### C. coding_agents — `dot_ansible/roles/coding_agents/tasks/main.yml`

**C1.** `Install Claude Code (Linux)` (line 48): add `target_architecture in ['x86_64','aarch64','arm64']` guard. The `install.sh` from `claude.ai` does not support armhf — downloads an arm64 binary that can't exec. Emit a debug msg pointing to manual install if the user really wants it.

**C2.** (macOS carry-over) Replace the existing npm-based Claude Code install for both macOS and Linux x86_64/arm64 with the official native installer: `curl -fsSL https://claude.ai/install.sh | bash`. Currently the Linux path already uses `install.sh`, so this change is mostly to the macOS block — remove the npm global install and use `install.sh` there too. Keep `creates:` idempotency pointing at `~/.claude/local/bin/claude`.

### D. brew bundle sudo pre-auth — `run_onchange_after_30_brew_bundle.sh.tmpl`

Add the same guard used by `run_onchange_after_20_ansible_roles.sh.tmpl` (added in `c4baaeb`): on macOS, if `sudo` is available and a TTY is attached, run `sudo -v` once before the first `brew bundle` call so pkg-bundled casks (google-drive, squirrel, ollama-app) can invoke `/usr/sbin/installer` non-interactively during the 5-min sudo timestamp window. Place after PATH setup (line 64) and before `info "Running brew bundle..."` (line 75).

## Reused patterns (don't re-invent)

- `target_architecture` fact: `dot_ansible/playbooks/linux.yml:16-33`
- Skip-on-unsupported-arch pattern: `dot_ansible/roles/devtools/tasks/main.yml:60-77` (`gh` block)
- Sudo pre-auth pattern: commit `c4baaeb` in `run_onchange_after_20_ansible_roles.sh.tmpl`
- Existing armv7l skips to model: gh, glab, diffnav, glow, sesh, taplo, television (all in devtools/main.yml)

## Verification

On RPi 4 (armhf):
```bash
chezmoi apply --dry-run                       # should skip delta/tldr/claude/bun/ruby with clear msgs
cd ~/.ansible && ansible-playbook playbooks/linux.yml --tags lazyvim_deps,devtools,coding_agents --check
# real run:
chezmoi update --init
# confirm: no 30-min mise node build loop; no Claude install attempt; delta/tldr skipped gracefully
mise ls                                       # node@20 present (not 24), no bun, no ruby
```

On macOS:
```bash
chezmoi state delete-bucket --bucket=scriptState   # force re-run of 30_brew_bundle
chezmoi apply
# Touch ID or password prompt should appear once at start of brew bundle;
# google-drive / squirrel / ollama-app install without "Input/output error"
ls /Library/Input\ Methods/ | grep -i squirrel
```

Syntax checks (per CLAUDE.md §Development):
```bash
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
```
