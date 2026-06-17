# Agent sandbox: an isolated box that runs Claude Code and Codex as
# ACP agents for Zed. Zed reaches in over stdio via `docker exec`.
FROM node:22-bookworm-slim

# System tools the agents rely on at runtime.
#   git            - version control operations
#   ripgrep        - fast code search the agents call out to
#   openssh-client - git-over-ssh
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ripgrep \
        ca-certificates \
        curl \
        less \
        openssh-client \
        bubblewrap \
        python3 \
        jq \
        make \
        unzip \
        zip \
        patch \
        sqlite3 \
        file \
        tree \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (not in the standard Debian repos).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ACP adapters are what Zed actually speaks to (bins: claude-agent-acp, codex-acp).
# The plain CLIs (claude, codex) are included so you can log in / poke around
# interactively inside the container.
RUN npm install -g \
        @agentclientprotocol/claude-agent-acp \
        @anthropic-ai/claude-code \
        @zed-industries/codex-acp \
        @openai/codex \
    && npm cache clean --force

# uv: fast Python package manager and project tool.
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

# The base image ships a non-root `node` user (uid/gid 1000); run as it.
# Pre-create the credential dirs so the named volumes mounted there inherit
# `node` ownership instead of defaulting to root.
RUN mkdir -p /home/node/.claude /home/node/.codex \
    && chown -R node:node /home/node/.claude /home/node/.codex

USER node
ENV HOME=/home/node
WORKDIR /home/node

# Keep the sandbox alive so Zed can `docker exec` into it on demand.
CMD ["sleep", "infinity"]
