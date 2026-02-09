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

# Show what would change
chezmoi-diff:
    chezmoi diff

# Apply dotfiles
chezmoi-apply:
    chezmoi apply

# Dry run (preview without applying)
chezmoi-dry-run:
    chezmoi apply --dry-run

# Show chezmoi status
chezmoi-status:
    chezmoi status

# Re-initialize chezmoi (for testing prompts)
chezmoi-reinit:
    chezmoi init

# Clear run_once script state (allows re-running run_once scripts)
chezmoi-clear-scripts:
    chezmoi state delete-bucket --bucket=scriptState

# Clear script state and re-apply (for testing run_once scripts)
chezmoi-rerun-scripts:
    chezmoi state delete-bucket --bucket=scriptState
    chezmoi apply -v

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

# Install pre-commit tool (auto-detects brew on macOS, uv, or pip)
pre-commit-install-tool:
    #!/usr/bin/env bash
    if command -v pre-commit &> /dev/null; then
        echo "pre-commit is already installed: $(pre-commit --version)"
        exit 0
    fi
    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &> /dev/null; then
        echo "Installing pre-commit via Homebrew..."
        brew install pre-commit
    elif command -v uv &> /dev/null; then
        echo "Installing pre-commit via uv..."
        uv tool install pre-commit
    elif command -v pip &> /dev/null; then
        echo "Installing pre-commit via pip..."
        pip install pre-commit
    else
        echo "Error: No package manager found. Install brew, uv, or pip first."
        exit 1
    fi
    echo "pre-commit installed: $(pre-commit --version)"

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

# Check for secrets in staged .specstory files (reports only)
check-specstory:
    ./scripts/redact_specstory.py || true

# Auto-redact secrets in staged .specstory files (review with git diff, then stage manually)
redact-specstory:
    ./scripts/redact_specstory.py --fix

# Check for secrets in working directory .specstory files
check-specstory-workdir:
    ./scripts/redact_specstory.py --working-dir || true

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

# Run tests (docker test suite)
test: docker-test

# Full check (lint + dry-run)
check: lint chezmoi-dry-run

# Show git status
status:
    @git status

# Show git diff
diff:
    @git diff

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
# Ad-hoc Scripts
# ============================================================================

# Test Ubuntu mirror
test-ubuntu-mirror:
    ./scripts/adhoc/test_ubuntu_mirror.sh
