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

# Build all CentOS-family images (centos7, centos7-noroot, rocky9, rocky9-noroot)
docker-build-centos-all:
    docker compose --profile centos build
    docker compose --profile rocky build

# Build CentOS 7 images (sudo + noRoot flavors)
docker-build-centos7:
    docker compose --profile centos build centos7 centos7-noroot

# Build Rocky 9 images (sudo + noRoot flavors)
docker-build-rocky9:
    docker compose --profile rocky build rocky9 rocky9-noroot

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

# Run smoke tests against CentOS 7 image (noRoot path — corporate scenario)
docker-test-centos7:
    docker compose --profile test run --build --rm test-centos7

# Run smoke tests against Rocky 9 image (modern dnf-native RHEL-family)
docker-test-rocky9:
    docker compose --profile test run --build --rm test-rocky9

# Run smoke tests against all CentOS-family images
docker-test-centos-all: docker-test-centos7 docker-test-rocky9

# Build and run desktop profile
docker-desktop:
    docker compose --profile desktop up -d desktop && docker compose exec desktop bash

# Build and run china profile
docker-china:
    docker compose --profile china up -d china && docker compose exec china bash

# Build and run CentOS 7 (sudo path) interactively
docker-run-centos7:
    docker compose --profile centos up -d centos7 && docker compose exec centos7 bash

# Build and run CentOS 7 (noRoot path — closest to corporate scenario) interactively
docker-run-centos7-noroot:
    docker compose --profile centos up -d centos7-noroot && docker compose exec centos7-noroot bash

# Build and run Rocky 9 (sudo path) interactively
docker-run-rocky9:
    docker compose --profile rocky up -d rocky9 && docker compose exec rocky9 bash

# Build and run Rocky 9 (noRoot path) interactively
docker-run-rocky9-noroot:
    docker compose --profile rocky up -d rocky9-noroot && docker compose exec rocky9-noroot bash

# Remove all dotfiles containers and images
docker-clean:
    docker compose down -v --rmi all 2>/dev/null || true
    docker compose --profile centos --profile rocky --profile test --profile desktop --profile china down -v --rmi all 2>/dev/null || true
    docker image rm dotfiles:server dotfiles:desktop dotfiles:china dotfiles:test 2>/dev/null || true
    docker image rm dotfiles:centos7 dotfiles:centos7-noroot dotfiles:rocky9 dotfiles:rocky9-noroot 2>/dev/null || true
    docker image rm dotfiles:test-centos7 dotfiles:test-rocky9 2>/dev/null || true

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

# Apply with sudo password injected via CHEZMOI_SUDO_PASSWORD_FILE.
# For environments where chezmoi-spawned run-scripts can't open /dev/tty
# (CentOS 7 + AD/LDAP user, missing pam_systemd, SSH without proper PAM
# session, etc.). See pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md.
# Prompts once, validates against sudo, shreds tmpfile on exit.
#     just apply-with-sudo                      # interactive prompt
#     just apply-with-sudo --pass-from-env      # uses $SUDO_PASSWORD env var
#     just apply-with-sudo --pass-from-file ~/.cz_sudo
apply-with-sudo *ARGS:
    bash scripts/apply_with_sudo.sh {{ARGS}}

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
#     just bootstrap-local -- doctor        # schema parity check (alias for gen --check)
#     just bootstrap-local -- list-bundles  # show bundles
#     just bootstrap-local --yes --bundle minimal  # non-interactive
bootstrap-local *ARGS:
    @echo "[bootstrap-local] running scripts/init/dotfiles_init.py from local source"
    uv run --script scripts/init/dotfiles_init.py {{ARGS}}

# Verbose bootstrap-local: shows uv resolver output (download/build steps).
bootstrap-local-verbose *ARGS:
    @echo "[bootstrap-local-verbose] uv --verbose; expect lots of resolver output"
    uv run --verbose --script scripts/init/dotfiles_init.py {{ARGS}}

# Reconfigure an ALREADY-initialized machine. Seeds the same grouped TUI from
# your current ~/.config/chezmoi/chezmoi.toml values, then runs
# `chezmoi init --apply --prompt` so the new answers actually take effect
# (the `--prompt` is what re-fires promptXOnce; without it the old values win).
# Non-interactive single-key changes (space-separated, for scripts / fleet):
#     just reconfigure --set installLlmTools=true motdStyle=figlet --yes
#     just reconfigure --dry-run        # preview the chezmoi command
reconfigure *ARGS:
    uv run --script scripts/init/dotfiles_init.py reconfigure {{ARGS}}

# Regenerate the chezmoi prompt blocks (.chezmoi.toml.tmpl + Dockerfile) from
# PROMPTS in scripts/init/dotfiles_init.py — the single source of truth. Run
# after editing PROMPTS, then commit the regenerated files. The pre-commit
# `dotfiles-init-gen-check` hook (or `just gen-prompts --check`) fails on drift.
gen-prompts *ARGS:
    uv run --script scripts/init/dotfiles_init.py gen --source . {{ARGS}}

# Clear run_once script state (allows re-running run_once scripts)
chezmoi-clear-scripts:
    chezmoi state delete-bucket --bucket=scriptState

# Clear script state and re-apply (for testing run_once scripts)
chezmoi-rerun-scripts:
    chezmoi state delete-bucket --bucket=scriptState
    chezmoi --no-pager apply -v

# ============================================================================
# Dotfiles backup (~/.dotfiles_backup)
# ============================================================================
#
# Pre-apply snapshots produced by `run_before_01_backup_dotfiles.sh.tmpl`.
# `backupMode` ∈ {smart (default), full, off}; smart only captures files
# `chezmoi apply` would overwrite/delete (per `chezmoi status` col 2 = M/D).

# List backup snapshots with file count
list-backups:
    @if [ ! -d "$HOME/.dotfiles_backup" ]; then echo "No backups in ~/.dotfiles_backup"; exit 0; fi
    @for d in "$HOME"/.dotfiles_backup/*/; do \
        [ -d "$d" ] || continue; \
        ts=$(basename "$d"); \
        n=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' '); \
        printf '%s  (%s file(s))\n' "$ts" "$n"; \
    done

# Diff a backup snapshot against current files in ~ (read-only inspection)
diff-backup ts:
    @snap="$HOME/.dotfiles_backup/{{ts}}"; \
    if [ ! -d "$snap" ]; then echo "No such backup: {{ts}}" >&2; exit 1; fi; \
    find "$snap" -type f | while read -r backed; do \
        rel="${backed#$snap/}"; live="$HOME/$rel"; \
        if [ ! -e "$live" ]; then \
            printf '\n=== %s: in backup, missing from live ===\n' "$rel"; \
        elif ! cmp -s "$backed" "$live"; then \
            printf '\n=== %s ===\n' "$rel"; \
            diff -u "$backed" "$live" || true; \
        fi; \
    done

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

# Broad shellcheck pass across managed shell modules at severity=warning.
# Pre-commit covers the same files at severity=error (blocks on real bugs);
# this recipe surfaces softer suggestions for gradual cleanup and exits
# non-zero on findings so CI can gate on it once the corpus is clean.
# Uses uvx-bundled shellcheck so a fresh host without devtools applied
# still gets coverage. System `shellcheck` (from devtools) is used when
# present — saves the uvx round-trip.
lint-shell:
    @if command -v shellcheck >/dev/null 2>&1; then \
        shellcheck --shell=bash --severity=warning \
            dot_config/shell/*.sh dot_config/bash/*.bash scripts/*.sh scripts/lib/*.sh; \
    else \
        uvx --quiet --from shellcheck-py shellcheck --shell=bash --severity=warning \
            dot_config/shell/*.sh dot_config/bash/*.bash scripts/*.sh scripts/lib/*.sh; \
    fi

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

# Force-regenerate shell completion files for upstream CLIs (chezmoi/mise/uv/
# just/starship/gh/docker/rg/fd/bat/delta/zellij/pueue/opencode). Normally
# `chezmoi apply` does this automatically (binary-mtime check, idempotent);
# use this recipe to refresh after a tool upgrade outside chezmoi (e.g. cargo
# install) or to reset a corrupted completion file.
# See docs/zsh/zsh-completions.md Section A for the inventory.
completions-refresh:
    ./scripts/generate_completions.sh --force

# Upgrade everything: externals, brew, mise, uv, npm, cargo, go, dotnet, gem, flatpak, warp, atuin, herdr, agents, plugins
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

# `go install <pkg>@latest` per tool in go_tools defaults (installs to ~/.local/bin)
upgrade-go:
    ./scripts/upgrade_tools.sh go

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

# Linux-only: `atuin update` (re-runs setup.atuin.sh on failure). macOS atuin is in upgrade-brew.
upgrade-atuin:
    ./scripts/upgrade_tools.sh atuin

# Linux-only: `herdr update --handoff` (live, pane-preserving). Must be run from
# OUTSIDE herdr after detaching (prefix+q) — the handoff replaces the server that
# owns your pane, so herdr refuses from inside one. macOS herdr is in upgrade-brew
# (upstream disables `herdr update` on brew installs). See docs/tools/herdr.md.
upgrade-herdr:
    ./scripts/upgrade_tools.sh herdr

# curl|bash installers: Claude Code, OpenCode, Cursor CLI, Ollama, llmfit, RTK
upgrade-agents:
    ./scripts/upgrade_tools.sh agents

# LazyVim (:Lazy sync) + TPM + claude-hud + pre-commit autoupdate + tldr + gh extensions
upgrade-plugins:
    ./scripts/upgrade_tools.sh plugins

# Yazi plugins: ya pkg upgrade (piper.yazi, …). Copy ~/.config/yazi/package.toml
# back into the chezmoi source afterward to persist the new revs.
upgrade-yazi-plugins:
    ./scripts/upgrade_tools.sh yazi-plugins

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

# Umbrella `fleet` CLI — same binary chezmoi deploys to ~/.dotfiles/bin/fleet,
# but run from the source tree (works before first `chezmoi apply`). Subcommands:
# apply / status / diff / tail / kill / compact / edit / tmux / info / pueue.
# Prefer this over `fleet-*` recipes when invoking from inside the repo;
# the old recipes stay as muscle-memory aliases.
fleet *ARGS:
    @uv run --script ./dot_dotfiles/bin/executable_fleet {{ARGS}}

# MLflow CLI umbrella — wraps `tv mlflow` plus open / copy / plot / list /
# download subcommands. See dot_dotfiles/bin/executable_mlf for surface.
mlf *ARGS:
    @uv run --script ./dot_dotfiles/bin/executable_mlf {{ARGS}}

# appsrc — detect how an installed app / CLI was installed & managed.
# `just appsrc which docker` / `just appsrc scan` / `just appsrc scan --json`.
# Same binary chezmoi deploys to ~/.dotfiles/bin/appsrc; run from source here.
appsrc *ARGS:
    @uv run --script ./dot_dotfiles/bin/executable_appsrc {{ARGS}}

# Apply chezmoi update to all configured hosts in parallel
fleet-apply *ARGS:
    ./scripts/fleet/apply.py {{ARGS}}

# Edit fleet inventory (~/.config/fleet/machines.toml). Seeds an empty
# template on first run; opens with $EDITOR (defaults to nvim).
fleet-edit:
    @mkdir -p ~/.config/fleet
    @if [ ! -f ~/.config/fleet/machines.toml ]; then \
        echo "[INFO] seeding empty ~/.config/fleet/machines.toml — add [[hosts]] entries below"; \
        printf '# fleet-apply inventory — see docs/this_repo/fleet-apply.md\n# Schema reference: dot_config/fleet/create_private_machines.toml.tmpl\n\n[defaults]\nchezmoi_path    = "auto"\nconnect_timeout = 30\ncommand_timeout = 7200\n\n# [[hosts]]\n# name      = "lab-box"\n# ssh_alias = "lab-box"\n# no_root_machine = false\n# password_source = { type = "prompt" }\n' > ~/.config/fleet/machines.toml; \
        chmod 600 ~/.config/fleet/machines.toml; \
    fi
    "${EDITOR:-nvim}" ~/.config/fleet/machines.toml


# Pre-flight readiness probe across all configured hosts. Predicts what
# `just fleet-apply` would do per host (up-to-date / behind / drift / busy
# / toml-mismatch / not-init / unreachable / ...) WITHOUT changing anything.
# Read-only, ~1.5s per host (with `git fetch`). See docs/this_repo/fleet-apply.md
# § Readiness probe.
fleet-status *ARGS:
    ./scripts/fleet/apply.py --readiness {{ARGS}}

# Like fleet-status but skip remote `git fetch` (faster, but 'behind' state
# may be stale). Useful offline or when you only care about drift / busy.
fleet-status-quick *ARGS:
    ./scripts/fleet/apply.py --readiness --readiness-no-fetch {{ARGS}}


# Preview only: runs `chezmoi diff` on every host (no changes applied)
fleet-apply-dry-run *ARGS:
    ./scripts/fleet/apply.py --dry-run {{ARGS}}

# Quick `chezmoi diff` against ONE host (serial, debug-friendly output).
# Use this in vibe loops to see exactly what your latest commit will do
# on a specific machine before pushing/applying for real.
fleet-diff HOST *ARGS:
    ./scripts/fleet/apply.py --dry-run --hosts {{HOST}} --serial {{ARGS}}

# Apply ONLY a single chezmoi target on each host (skips ansible / Brewfile).
# PATH is the chezmoi target path, e.g. `.config/zsh/aliases.zsh` or
# `.zshrc`. Fast feedback for editing one dotfile across the fleet without
# waiting for full Linuxbrew/ansible cycles. Pass extra `--hosts HOST` to
# scope. Internally sets CHEZMOI_FLEET_APPLY_PATH so the wrapper runs
# `chezmoi apply <relpath>` instead of `chezmoi update --init`.
fleet-apply-file PATH *ARGS:
    ./scripts/fleet/apply.py --apply-only-path {{PATH}} {{ARGS}}

# Apply a feature BRANCH instead of pulling main. Each remote does
# `git fetch origin BRANCH && git checkout -B BRANCH origin/BRANCH &&
# git merge --ff-only origin/BRANCH` before chezmoi apply. Fails loud
# on divergence — use `just fleet-apply-branch-force` to nuke local
# state with `git reset --hard`. Local hosts skip this entirely (source
# is your editor's working tree).
fleet-apply-branch BRANCH *ARGS:
    ./scripts/fleet/apply.py --branch {{BRANCH}} {{ARGS}}

# Like fleet-apply-branch but uses `git reset --hard origin/BRANCH` on
# remotes, destroying any local divergence. Use after force-pushing a
# rebased topic branch so every host follows.
fleet-apply-branch-force BRANCH *ARGS:
    ./scripts/fleet/apply.py --branch {{BRANCH}} --force-checkout {{ARGS}}

# Apply to a single named host in --serial mode (debug-friendly output)
fleet-apply-one HOST *ARGS:
    ./scripts/fleet/apply.py --hosts {{HOST}} --serial {{ARGS}}

# Kill orphan chezmoi/ansible processes on every host (cleanup after Ctrl+C)
fleet-apply-kill *ARGS:
    ./scripts/fleet/apply.py --kill-orphans {{ARGS}}

# Probe each host for running chezmoi/ansible (use after killing local SSH)
fleet-apply-status *ARGS:
    ./scripts/fleet/apply.py --status {{ARGS}}

# Like fleet-apply-status but re-poll every Ns until everyone is idle
# (Ctrl+C to stop). Default interval 10s; override with --watch=N in ARGS.
fleet-apply-watch *ARGS:
    ./scripts/fleet/apply.py --status --watch 10 {{ARGS}}

# Live-tail the remote fleet-apply log of HOST (defaults to most recent run);
# pass `HOST:RUN_ID` (e.g. lab-box:20260422T133615Z) to pin a specific run.
# Ctrl+C stops the viewer only — the remote run keeps going.
fleet-apply-tail HOST *ARGS:
    ./scripts/fleet/apply.py --tail {{HOST}} {{ARGS}}

# Compact post-mortem summary across the fleet: final task reached, ansible
# runtime, top slow tasks, failed run_* script, exit code. Defaults to each
# host's latest run; pin to one run with --compact-run-id RUN_ID in ARGS.
fleet-apply-compact *ARGS:
    ./scripts/fleet/apply.py --compact {{ARGS}}

# ============================================================================
# Azure dev VM (scripts/azure/dev_vm.py — docs/this_repo/az-dev-vm.md)
# ============================================================================

# One command -> running Azure dev VM with the lean cloud-vm bundle applied:
# az vm create (idempotent, B2s/32GB) + auto-shutdown guardrail + wait for SSH
# + remote non-interactive `chezmoi init --apply --bundle cloud-vm` + register
# in ~/.config/fleet/machines.toml. GPU seam: `just az-dev-vm --gpu`.
az-dev-vm *ARGS:
    ./scripts/azure/dev_vm.py up {{ARGS}}

# Teardown (symmetric to az-dev-vm): delete the VM + its resources (whole
# resource group when this VM is the only one in it) and de-register the host
# from the fleet inventory. Prompts for the VM name unless --yes.
az-dev-vm-down *ARGS:
    ./scripts/azure/dev_vm.py down {{ARGS}}

# Power state / public IP / size of every VM in the dev resource group.
az-dev-vm-status *ARGS:
    ./scripts/azure/dev_vm.py status {{ARGS}}

# Resolve the VM's public IP and ssh in.
az-dev-vm-ssh *ARGS:
    ./scripts/azure/dev_vm.py ssh {{ARGS}}

# ============================================================================
# Ad-hoc Scripts
# ============================================================================

# Test Ubuntu mirror
test-ubuntu-mirror:
    ./scripts/adhoc/test_ubuntu_mirror.sh
