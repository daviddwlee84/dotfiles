# Dotfiles test/devbox container
# Build: docker build -t dotfiles .
# Run:   docker run -it dotfiles

FROM ubuntu:24.04

# Build arguments for chezmoi configuration
ARG CHEZMOI_PROFILE=ubuntu_server
ARG CHEZMOI_EMAIL=docker@example.com
ARG CHEZMOI_NAME="Docker User"
ARG CHEZMOI_USE_CHINESE_MIRROR=false
ARG CHEZMOI_REPO=daviddwlee84

# Avoid interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Configure TUNA mirror for faster downloads in China (if enabled)
# Ubuntu 24.04 uses DEB822 format in /etc/apt/sources.list.d/ubuntu.sources
# Handles both amd64 (ubuntu) and arm64 (ubuntu-ports)
RUN if [ "${CHEZMOI_USE_CHINESE_MIRROR}" = "true" ]; then \
        ARCH=$(dpkg --print-architecture) && \
        if [ "$ARCH" = "amd64" ]; then \
            MIRROR_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"; \
        else \
            MIRROR_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"; \
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
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    sudo \
    git \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user with sudo access
RUN useradd -m -s /bin/bash devuser \
    && echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/devuser \
    && chmod 0440 /etc/sudoers.d/devuser

# Switch to non-root user
USER devuser
WORKDIR /home/devuser

# Pre-create chezmoi config to avoid interactive prompts
RUN mkdir -p /home/devuser/.config/chezmoi \
    && echo "[data]" > /home/devuser/.config/chezmoi/chezmoi.toml \
    && echo "profile = \"${CHEZMOI_PROFILE}\"" >> /home/devuser/.config/chezmoi/chezmoi.toml \
    && echo "email = \"${CHEZMOI_EMAIL}\"" >> /home/devuser/.config/chezmoi/chezmoi.toml \
    && echo "name = \"${CHEZMOI_NAME}\"" >> /home/devuser/.config/chezmoi/chezmoi.toml \
    && echo "useChineseMirror = ${CHEZMOI_USE_CHINESE_MIRROR}" >> /home/devuser/.config/chezmoi/chezmoi.toml

# Install chezmoi and apply dotfiles
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply ${CHEZMOI_REPO}

# Default to bash shell
CMD ["/bin/bash"]
