# Dotfiles test/devbox container
# Build: docker build -t dotfiles .
# Run:   docker run -it dotfiles

FROM ubuntu:24.04

# Build arguments for chezmoi configuration
ARG CHEZMOI_PROFILE=ubuntu_server
ARG CHEZMOI_EMAIL=docker@example.com
ARG CHEZMOI_NAME="Docker User"
ARG CHEZMOI_USE_CHINESE_MIRROR=false
ARG CHEZMOI_GITLEAKS_ALL_REPOS=false
ARG CHEZMOI_INSTALL_CODING_AGENTS=false
ARG CHEZMOI_INSTALL_BITWARDEN=false
ARG CHEZMOI_INSTALL_PYTHON_UV_TOOLS=false
ARG CHEZMOI_INSTALL_JS_CLI_TOOLS=false
ARG CHEZMOI_INSTALL_LLM_TOOLS=false
ARG CHEZMOI_INSTALL_AI_DESKTOP_APPS=false
ARG CHEZMOI_INSTALL_BREW_APPS=false
ARG CHEZMOI_INSTALL_INPUT_METHOD=false
ARG CHEZMOI_DISCORD_CHANNEL=none
ARG CHEZMOI_INSTALL_NETWORKING_TOOLS=false
ARG CHEZMOI_INSTALL_IAC_TOOLS=false
ARG CHEZMOI_INSTALL_MEDIA_TOOLS=false
ARG CHEZMOI_INSTALL_DOTNET_TOOLS=false
ARG CHEZMOI_NO_ROOT=false
ARG CHEZMOI_BACKUP_MODE=off
ARG CHEZMOI_ALLOW_PARTIAL_FAILURE=false
ARG CHEZMOI_MOTD_STYLE=figlet
ARG CHEZMOI_REPO=daviddwlee84

# Avoid interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Configure HTTP mirror BEFORE installing ca-certificates (if in China)
# This solves the chicken-and-egg problem: HTTPS mirrors need ca-certificates,
# but installing ca-certificates from default repos fails under GFW
# Uses HTTP (not HTTPS) since ca-certificates isn't installed yet
RUN if [ "${CHEZMOI_USE_CHINESE_MIRROR}" = "true" ]; then \
        ARCH=$(dpkg --print-architecture) && \
        if [ "$ARCH" = "amd64" ]; then \
            MIRROR_URL="http://repo.huaweicloud.com/ubuntu"; \
        else \
            MIRROR_URL="http://repo.huaweicloud.com/ubuntu-ports"; \
        fi && \
        printf '%s\n' \
            "Types: deb" \
            "URIs: ${MIRROR_URL}" \
            "Suites: noble noble-updates noble-backports" \
            "Components: main restricted universe multiverse" \
            "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg" \
            "" \
            "Types: deb" \
            "URIs: ${MIRROR_URL}" \
            "Suites: noble-security" \
            "Components: main restricted universe multiverse" \
            "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg" \
            > /etc/apt/sources.list.d/ubuntu.sources; \
    fi

# Install ca-certificates (now using HTTP mirror if in China, default repos otherwise)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Upgrade to HTTPS mirror after ca-certificates is installed (if in China)
# HTTPS is more secure for subsequent package installations
RUN if [ "${CHEZMOI_USE_CHINESE_MIRROR}" = "true" ]; then \
        ARCH=$(dpkg --print-architecture) && \
        if [ "$ARCH" = "amd64" ]; then \
            MIRROR_URL="https://repo.huaweicloud.com/ubuntu"; \
        else \
            MIRROR_URL="https://repo.huaweicloud.com/ubuntu-ports"; \
        fi && \
        printf '%s\n' \
            "Types: deb" \
            "URIs: ${MIRROR_URL}" \
            "Suites: noble noble-updates noble-backports" \
            "Components: main restricted universe multiverse" \
            "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg" \
            "" \
            "Types: deb" \
            "URIs: ${MIRROR_URL}" \
            "Suites: noble-security" \
            "Components: main restricted universe multiverse" \
            "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg" \
            > /etc/apt/sources.list.d/ubuntu.sources; \
    fi

# Install minimal dependencies
# - python3: required for ansible to run modules on localhost
# - jq:      required by modify_ chezmoi scripts (e.g. dot_agents/modify_dot_skill-lock.json.tmpl)
#            which run during `chezmoi apply` BEFORE the ansible base role
#            installs jq system-wide. Without it chezmoi exits with
#            `.agents/.skill-lock.json: exit status 127` (jq: command not found).
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    sudo \
    git \
    python3 \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user with sudo access
RUN useradd -m -s /bin/bash devuser \
    && echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/devuser \
    && chmod 0440 /etc/sudoers.d/devuser

# Copy local dotfiles source into image
# This allows testing local changes without pushing to GitHub
COPY --chown=devuser:devuser . /tmp/dotfiles-source

# Switch to non-root user
USER devuser
WORKDIR /home/devuser

# Make ~/.local/bin available to all subsequent CMDs (bats, chezmoi, mise,
# uv, just, fd, etc. all live there after ansible's user-level installs).
# Docker's CMD doesn't load ~/.bashrc, so without this the test service's
# `command: ["bats", ...]` exits 127 even though bats is installed.
ENV PATH="/home/devuser/.local/bin:${PATH}"

# Install chezmoi binary
# Retry up to 3 times to handle network issues (especially behind GFW)
RUN for i in 1 2 3; do \
        echo "Attempt $i: Installing chezmoi to ~/.local/bin..." && \
        sh -c "$(curl -fsLS --retry 3 --retry-delay 5 get.chezmoi.io/lb)" && \
        echo "chezmoi installed successfully" && break || \
        { echo "Attempt $i failed, retrying..."; sleep 10; }; \
    done

# Initialize and apply dotfiles with prompt values passed via flags
# This avoids interactive prompts during Docker build
# Set PATH to include ~/.local/bin so run_once scripts can find uv tools (ansible)
# Use local source instead of cloning from GitHub to test local changes
# Note: installBrewApps=false and installAiDesktopApps=false by default
RUN export PATH="$HOME/.local/bin:$PATH" && \
    ~/.local/bin/chezmoi init --apply --source=/tmp/dotfiles-source \
    --promptChoice "Which profile=${CHEZMOI_PROFILE}" \
    --promptString "What is your email address=${CHEZMOI_EMAIL}" \
    --promptString "What is your full name=${CHEZMOI_NAME}" \
    --promptBool "Are you in China (behind GFW) and need to use mirrors=${CHEZMOI_USE_CHINESE_MIRROR}" \
    --promptBool "Enable gitleaks for ALL git repos (not just those with .pre-commit-config.yaml)=${CHEZMOI_GITLEAKS_ALL_REPOS}" \
    --promptBool "Install coding agents (Claude Code, OpenCode, Cursor, Copilot, Gemini, etc.)=${CHEZMOI_INSTALL_CODING_AGENTS}" \
    --promptBool "Install Bitwarden CLI (and Desktop on ubuntu_desktop/macOS — snap or .deb on Linux, Cask on macOS) with SSH Agent integration=${CHEZMOI_INSTALL_BITWARDEN}" \
    --promptBool "Install Python CLI tools via uv (mlflow, sqlit-tui, tmuxp, etc.)=${CHEZMOI_INSTALL_PYTHON_UV_TOOLS}" \
    --promptBool "Install standalone JS/npm CLI utilities (readability-cli for terminal web reader, etc.)=${CHEZMOI_INSTALL_JS_CLI_TOOLS}" \
    --promptBool "Install local LLM tools (Ollama, LiteLLM, llmfit, models)=${CHEZMOI_INSTALL_LLM_TOOLS}" \
    --promptBool "Install AI desktop apps via macOS Homebrew Brewfile (Claude, ChatGPT, OpenCode, Antigravity, Codex, Ollama app)=${CHEZMOI_INSTALL_AI_DESKTOP_APPS}" \
    --promptBool "Install general GUI apps via Homebrew Brewfile (terminals, browsers, utilities, etc.; excludes AI desktop apps)=${CHEZMOI_INSTALL_BREW_APPS}" \
    --promptBool "Install Traditional Chinese input methods (McBopomofo, RIME)=${CHEZMOI_INSTALL_INPUT_METHOD}" \
    --promptChoice "Discord install channel (flatpak|deb|none)=${CHEZMOI_DISCORD_CHANNEL}" \
    --promptBool "Install networking CLI tools (nmap, mtr, httpie, gping, trippy, etc.)=${CHEZMOI_INSTALL_NETWORKING_TOOLS}" \
    --promptBool "Install Infrastructure-as-Code tools (Azure CLI, Terraform, OpenTofu)=${CHEZMOI_INSTALL_IAC_TOOLS}" \
    --promptBool "Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)=${CHEZMOI_INSTALL_MEDIA_TOOLS}" \
    --promptBool "Install .NET SDK via mise and dotnet global tools (azure-cost-cli, etc.)=${CHEZMOI_INSTALL_DOTNET_TOOLS}" \
    --promptBool "No sudo/root access - skip all system package installations=${CHEZMOI_NO_ROOT}" \
    --promptChoice "Backup mode for existing dotfiles (smart|full|off)=${CHEZMOI_BACKUP_MODE}" \
    --promptBool "Allow partial Ansible failures (continue installing other tools if one role fails)=${CHEZMOI_ALLOW_PARTIAL_FAILURE}" \
    --promptChoice "SSH login banner style (figlet|fastfetch-slim|fastfetch-full)=${CHEZMOI_MOTD_STYLE}"

# Default to bash shell
CMD ["/bin/bash"]
