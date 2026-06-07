FROM ubuntu:24.04

# curl is needed to download install.sh (not pre-installed in ubuntu:24.04)
RUN apt-get update -qq && apt-get install -y -qq curl gnupg && rm -rf /var/lib/apt/lists/*

# Copy the RDE config to disable web IDE components before running install.sh
COPY .config.rde.qovery.yml /tmp/.config.rde.qovery.yml

# Install RDE tooling (Claude Code, OpenCode, Codex, Cursor, proxy, git, jq, etc.)
# The config file disables code-server, the standard entrypoint, and other
# interactive-only components that aren't needed for headless autonomous mode.
# Bump RDE_INSTALL_VERSION to force a fresh install.sh run (cache bust).
ARG RDE_INSTALL_VERSION=2
RUN export RDE_CONFIG=/tmp/.config.rde.qovery.yml && \
    curl -fsSL https://rde.qovery.com/install.sh | bash

# Install our autonomous agent scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY agent-run.sh /usr/local/bin/agent-run.sh
COPY lib/ /usr/local/lib/agent/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/agent-run.sh \
    && chmod +x /usr/local/lib/agent/*.sh

# Create repo clone directory for agent-run.sh
RUN mkdir -p /repos && chown coder:coder /repos

WORKDIR /home/coder/project
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
