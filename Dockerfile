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
