# Dotfiles project manual
# Run `just` to see all available commands

# Default: show help
default:
    @just --list

# ============================================================================
# Docker
# ============================================================================

# Build the default Docker image (ubuntu_server)
docker-build:
    docker compose build devbox

# Build all Docker images
docker-build-all:
    docker compose build devbox
    docker compose --profile desktop build
    docker compose --profile china build

# Run interactive devbox shell
docker-run:
    docker compose up -d devbox && docker compose exec devbox bash

# Start devbox in background
docker-up:
    docker compose up -d devbox

# Stop devbox
docker-down:
    docker compose down

# Run test suite in container
docker-test:
    docker compose run --build --rm test

# Build and run desktop profile
docker-desktop:
    docker compose --profile desktop up -d desktop && docker compose exec desktop bash

# Build and run china profile
docker-china:
    docker compose --profile china up -d china && docker compose exec china bash

# Remove all dotfiles containers and images
docker-clean:
    docker compose down -v --rmi all 2>/dev/null || true
    docker image rm dotfiles:server dotfiles:desktop dotfiles:china dotfiles:test 2>/dev/null || true

# ============================================================================
# Chezmoi
# ============================================================================
#
# All `chezmoi-*` recipes pass `--no-pager` so output streams straight to
# stdout instead of spawning the configured pager (delta in this repo).
# Critical for non-interactive callers (CI, coding agents, `just` itself
# in scripted contexts) — without it, delta tries to alternate-screen
# / line-buffer over a pipe and either panics, hangs, or eats output.
# Use raw `chezmoi diff` directly when you want the interactive pager.

# Show what would change
chezmoi-diff:
    chezmoi --no-pager diff

# Apply dotfiles
chezmoi-apply:
    chezmoi --no-pager apply

# Dry run (preview without applying)
chezmoi-dry-run:
    chezmoi --no-pager apply --dry-run

# Show chezmoi status
chezmoi-status:
    chezmoi --no-pager status

# Re-initialize chezmoi (for testing prompts)
chezmoi-reinit:
    chezmoi init

# Run the interactive bootstrap wrapper from the LOCAL chezmoi source.
# Use this instead of `curl|bash` when you're on a slow / GFW-throttled network
# and have already cloned the repo. Skips the bootstrap.sh stage entirely:
# uv resolves PEP 723 deps locally; chezmoi init clones from the same remote
# you're cloned from. Pass extra args after `--`:
#     just bootstrap-local                  # interactive
#     just bootstrap-local -- doctor        # schema parity check
#     just bootstrap-local -- list-bundles  # show bundles
#     just bootstrap-local -- --yes --bundle minimal  # non-interactive
bootstrap-local *ARGS:
    @echo "[bootstrap-local] running scripts/init/dotfiles_init.py from local source"
    uv run --script scripts/init/dotfiles_init.py {{ARGS}}

# Verbose bootstrap-local: shows uv resolver output (download/build steps).
bootstrap-local-verbose *ARGS:
    @echo "[bootstrap-local-verbose] uv --verbose; expect lots of resolver output"
    uv run --verbose --script scripts/init/dotfiles_init.py {{ARGS}}

# Clear run_once script state (allows re-running run_once scripts)
chezmoi-clear-scripts:
    chezmoi state delete-bucket --bucket=scriptState

# Clear script state and re-apply (for testing run_once scripts)
chezmoi-rerun-scripts:
    chezmoi state delete-bucket --bucket=scriptState
    chezmoi --no-pager apply -v

# ============================================================================
# Ansible
# ============================================================================

# Ansible syntax check (all playbooks)
ansible-syntax-check:
    ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/base.yml
    ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
    ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml

# Run base playbook (from ~/.ansible)
ansible-base:
    cd ~/.ansible && ansible-playbook playbooks/base.yml

# Run macOS playbook
ansible-macos:
    cd ~/.ansible && ansible-playbook playbooks/macos.yml

# Run Linux playbook
ansible-linux:
    cd ~/.ansible && ansible-playbook playbooks/linux.yml --ask-become-pass

# Run playbook with specific tags (usage: just ansible-tags "neovim,lazyvim_deps")
ansible-tags tags:
    cd ~/.ansible && ansible-playbook playbooks/$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/').yml --tags "{{tags}}"

# Ansible dry run (check mode)
ansible-check:
    cd ~/.ansible && ansible-playbook playbooks/$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/').yml --check

# Install security tools (pre-commit, gitleaks)
ansible-security:
    cd ~/.ansible && ansible-playbook playbooks/$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/').yml --tags "security_tools"

# ============================================================================
# Security & Pre-commit
# ============================================================================

# Install pre-commit via uv (pinned to Python 3.13 — same command as the
# security_tools ansible role, so both paths converge on ~/.local/bin/pre-commit).
# Avoids the macOS Homebrew python@3.14 pyexpat ABI mismatch that breaks hook
# virtualenv creation. Run `just pre-commit-doctor` if hooks start failing.
pre-commit-install-tool:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v uv &>/dev/null; then
        echo "Error: uv not found on PATH. Run chezmoi bootstrap first (installs uv into ~/.local/bin), or install uv manually from https://astral.sh/uv." >&2
        exit 1
    fi
    uv tool install --force pre-commit --python 3.13
    echo "pre-commit installed: $(pre-commit --version) @ $(command -v pre-commit)"

# Set up pre-commit hooks in the repository
pre-commit-setup: pre-commit-install-tool
    pre-commit install
    @echo "Pre-commit hooks installed successfully!"
    @echo "Hooks will now run automatically on git commit."

# Run pre-commit on all files
pre-commit-run-all:
    pre-commit run --all-files

# Run pre-commit on staged files only
pre-commit-run:
    pre-commit run

# Update pre-commit hooks to latest versions
pre-commit-update:
    pre-commit autoupdate

# Uninstall pre-commit hooks
pre-commit-uninstall:
    pre-commit uninstall

# Diagnose broken pre-commit envs (pyexpat/virtualenv errors, conda/brew PATH
# shadowing) and re-install under uv if needed. First-line fix when
# `git commit` aborts with "An unexpected error has occurred: CalledProcessError".
pre-commit-doctor:
    ./scripts/pre-commit-doctor.sh

# Check for secrets in staged agent artifacts (specstory + coding-agent plans; reports only)
check-secrets:
    ./scripts/redact_secrets.py || true

# Auto-redact secrets in staged agent artifacts (review with git diff, then stage manually)
redact-secrets:
    ./scripts/redact_secrets.py --fix

# Check for secrets in working directory agent artifacts
check-secrets-workdir:
    ./scripts/redact_secrets.py --working-dir || true

# Legacy specstory-only shortcuts (thin wrappers over redact_secrets.py)
check-specstory:
    ./scripts/redact_secrets.py --paths .specstory/history || true

redact-specstory:
    ./scripts/redact_secrets.py --fix --paths .specstory/history

check-specstory-workdir:
    ./scripts/redact_secrets.py --working-dir --paths .specstory/history || true

# Scan entire repository for secrets with gitleaks
gitleaks-scan:
    gitleaks detect --source . --verbose

# Scan git history for secrets (thorough but slower)
gitleaks-scan-history:
    gitleaks detect --source . --verbose --log-opts="--all"

# ============================================================================
# Development
# ============================================================================

# Run all linting checks
lint: ansible-syntax-check pre-commit-run-all

# Run bats unit tests (fast, no Docker, no network)
bats:
    bats tests/unit

# Run tests (docker test suite)
test: docker-test

# Full check: ansible syntax + pre-commit + bats unit + docker smoke
check-all: lint bats docker-test

# Full check (lint + dry-run)
check: lint chezmoi-dry-run

# Show git status
status:
    @git status

# Show git diff
diff:
    @git diff

# Stage all changes, auto-redact secrets across agent artifacts (specstory +
# .claude/plans + .cursor/plans + .opencode/plans), and re-stage.
add-and-redact:
    @git add -A
    @just redact-secrets
    @git add -A

# ============================================================================
# Setup Utilities
# ============================================================================

# Full macOS setup
setup-macos: chezmoi-apply ansible-macos

# Full Linux setup
setup-linux: chezmoi-apply ansible-linux

# Set up development environment (includes security hooks)
setup-dev: pre-commit-setup
    @echo "Development environment ready!"
    @echo "Run 'just pre-commit-run-all' to scan existing files."

# Show system info
info:
    @echo "OS: $(uname -s)"
    @echo "Arch: $(uname -m)"
    @echo "Shell: $SHELL"
    @echo ""
    @echo "Chezmoi source: $(chezmoi source-path 2>/dev/null || echo 'not installed')"
    @echo "Ansible config: ~/.ansible"
    @echo ""
    @echo "Installed tools:"
    @echo -n "  chezmoi: "; chezmoi --version 2>/dev/null || echo "not installed"
    @echo -n "  ansible: "; ansible --version 2>/dev/null | head -1 || echo "not installed"
    @echo -n "  nvim: "; nvim --version 2>/dev/null | head -1 || echo "not installed"
    @echo -n "  git: "; git --version 2>/dev/null || echo "not installed"

# ============================================================================
# Upgrades (explicit, opt-in — `chezmoi apply` stays conservative)
# ============================================================================
# `chezmoi apply` is deliberately install-only: `state: present` / `creates:`
# don't move tools forward once installed (avoids "apply accidentally bumps
# every tool on the machine"). These recipes are the explicit upgrade path —
# run them when you actually want tools to advance.
# See `## Upgrades` section in AGENTS.md for rationale + category matrix.

# Upgrade everything: externals, brew, mise, uv, npm, cargo, dotnet, gem, flatpak, warp, agents, plugins
upgrade-all:
    ./scripts/upgrade_tools.sh all

# Homebrew formulas + casks (--greedy) + Brewfile (no --no-upgrade) + cleanup
upgrade-brew:
    ./scripts/upgrade_tools.sh brew

# mise self-update + `mise upgrade` (runtimes: node, rust, ruby, dotnet, bun)
upgrade-mise:
    ./scripts/upgrade_tools.sh mise

# uv self update + `uv tool upgrade --all` (Python CLI tools)
upgrade-uv:
    ./scripts/upgrade_tools.sh uv

# Global npm packages (falls back to `mise exec -- npm` when npm not on PATH)
upgrade-npm:
    ./scripts/upgrade_tools.sh npm

# cargo install-update -a (bootstraps cargo-update crate if missing)
upgrade-cargo:
    ./scripts/upgrade_tools.sh cargo

# `dotnet tool update --global <name>` per tool in dotnet_tools defaults
upgrade-dotnet:
    ./scripts/upgrade_tools.sh dotnet

# rubygems + installed gems (via mise ruby shim)
upgrade-gem:
    ./scripts/upgrade_tools.sh gem

# `flatpak update --user` for Flathub apps (Discord etc. when discordChannel=flatpak)
upgrade-flatpak:
    ./scripts/upgrade_tools.sh flatpak

# Linux-only: `apt install --only-upgrade warp-terminal` (macOS Warp is in upgrade-brew)
upgrade-warp:
    ./scripts/upgrade_tools.sh warp

# curl|bash installers: Claude Code, OpenCode, Cursor CLI, Ollama, llmfit, RTK
upgrade-agents:
    ./scripts/upgrade_tools.sh agents

# LazyVim (:Lazy sync) + TPM + claude-hud + pre-commit autoupdate + tldr + gh extensions
upgrade-plugins:
    ./scripts/upgrade_tools.sh plugins

# chezmoi upgrade + chezmoi apply --refresh-externals (oh-my-zsh, TPM, etc.)
upgrade-externals:
    ./scripts/upgrade_tools.sh externals

# Update already-installed global agent skills (refresh upstream content via
# content-hash compare). Does NOT backfill missing entries from
# ~/.agents/.skill-lock.json — that's `chezmoi apply`'s restore loop. Standalone
# for now (not wired into upgrade-all / upgrade_tools.sh; see TODO.md).
# See docs/tools/agent-skills.md.
upgrade-skills:
    npx -y skills@latest update --global -y

# Preview what `just upgrade-all` would do, without running anything
upgrade-dry-run:
    ./scripts/upgrade_tools.sh --dry-run all

# Restore project-scope agent skills (chezmoi repo only — global is auto-handled). See docs/tools/agent-skills.md
bootstrap-skills:
    @if [ ! -f skills-lock.json ]; then echo "[INFO] no skills-lock.json in repo root; nothing to restore"; exit 0; fi
    npx -y skills@latest experimental_install

# ============================================================================
# Fleet (multi-host chezmoi apply)
# ============================================================================
# Run `chezmoi update --init` (or apply / diff) across many remote hosts in
# parallel. Inventory: ~/.config/fleet/machines.toml (seeded by chezmoi as a
# `create_private_` template — your edits are preserved). Sudo password
# sources: plain / interactive prompt / Bitwarden CLI / none.
# Per-host log: logs/fleet-apply/<UTC-timestamp>/<host>.log
# Exit code = number of failed hosts.
# See docs/this_repo/fleet-apply.md for full schema and troubleshooting.

# Apply chezmoi update to all configured hosts in parallel
fleet-apply *ARGS:
    ./scripts/fleet_apply.py {{ARGS}}

# Preview only: runs `chezmoi diff` on every host (no changes applied)
fleet-apply-dry-run *ARGS:
    ./scripts/fleet_apply.py --dry-run {{ARGS}}

# Quick `chezmoi diff` against ONE host (serial, debug-friendly output).
# Use this in vibe loops to see exactly what your latest commit will do
# on a specific machine before pushing/applying for real.
fleet-diff HOST *ARGS:
    ./scripts/fleet_apply.py --dry-run --hosts {{HOST}} --serial {{ARGS}}

# Apply ONLY a single chezmoi target on each host (skips ansible / Brewfile).
# PATH is the chezmoi target path, e.g. `.config/zsh/aliases.zsh` or
# `.zshrc`. Fast feedback for editing one dotfile across the fleet without
# waiting for full Linuxbrew/ansible cycles. Pass extra `--hosts HOST` to
# scope. Internally sets CHEZMOI_FLEET_APPLY_PATH so the wrapper runs
# `chezmoi apply <relpath>` instead of `chezmoi update --init`.
fleet-apply-file PATH *ARGS:
    ./scripts/fleet_apply.py --apply-only-path {{PATH}} {{ARGS}}

# Apply a feature BRANCH instead of pulling main. Each remote does
# `git fetch origin BRANCH && git checkout -B BRANCH origin/BRANCH &&
# git merge --ff-only origin/BRANCH` before chezmoi apply. Fails loud
# on divergence — use `just fleet-apply-branch-force` to nuke local
# state with `git reset --hard`. Local hosts skip this entirely (source
# is your editor's working tree).
fleet-apply-branch BRANCH *ARGS:
    ./scripts/fleet_apply.py --branch {{BRANCH}} {{ARGS}}

# Like fleet-apply-branch but uses `git reset --hard origin/BRANCH` on
# remotes, destroying any local divergence. Use after force-pushing a
# rebased topic branch so every host follows.
fleet-apply-branch-force BRANCH *ARGS:
    ./scripts/fleet_apply.py --branch {{BRANCH}} --force-checkout {{ARGS}}

# Apply to a single named host in --serial mode (debug-friendly output)
fleet-apply-one HOST *ARGS:
    ./scripts/fleet_apply.py --hosts {{HOST}} --serial {{ARGS}}

# Kill orphan chezmoi/ansible processes on every host (cleanup after Ctrl+C)
fleet-apply-kill *ARGS:
    ./scripts/fleet_apply.py --kill-orphans {{ARGS}}

# Probe each host for running chezmoi/ansible (use after killing local SSH)
fleet-apply-status *ARGS:
    ./scripts/fleet_apply.py --status {{ARGS}}

# Like fleet-apply-status but re-poll every Ns until everyone is idle
# (Ctrl+C to stop). Default interval 10s; override with --watch=N in ARGS.
fleet-apply-watch *ARGS:
    ./scripts/fleet_apply.py --status --watch 10 {{ARGS}}

# Live-tail the remote fleet-apply log of HOST (defaults to most recent run);
# pass `HOST:RUN_ID` (e.g. lab-box:20260422T133615Z) to pin a specific run.
# Ctrl+C stops the viewer only — the remote run keeps going.
fleet-apply-tail HOST *ARGS:
    ./scripts/fleet_apply.py --tail {{HOST}} {{ARGS}}

# Compact post-mortem summary across the fleet: final task reached, ansible
# runtime, top slow tasks, failed run_* script, exit code. Defaults to each
# host's latest run; pin to one run with --compact-run-id RUN_ID in ARGS.
fleet-apply-compact *ARGS:
    ./scripts/fleet_apply.py --compact {{ARGS}}

# ============================================================================
# Ad-hoc Scripts
# ============================================================================

# Test Ubuntu mirror
test-ubuntu-mirror:
    ./scripts/adhoc/test_ubuntu_mirror.sh
