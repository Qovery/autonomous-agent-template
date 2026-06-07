#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Qovery Autonomous Agent — Entrypoint
#
# This is a self-contained entrypoint for autonomous agent workspaces.
# It starts the governance proxy (if configured), then runs agent-run.sh
# which performs the full autonomous cycle:
#   fetch Linear issue -> clone repo -> run AI agent -> push -> PR -> callback
# ────────────────────────────────────────────────────────────────────────────────
set -euo pipefail

log() { printf '[autonomous] %s\n' "$1"; }
log_error() { printf '[autonomous] [ERROR] %s\n' "$1" >&2; }

# ── Step 1: Start the agent governance proxy (if configured) ─────────────────
# The proxy intercepts all outbound HTTP(S) from the agent and applies org
# policies (allowlists, secret detection, rate limiting, kill switch).
# It must start BEFORE any network calls (git clone, Linear API, agent egress).

if [[ -n "${RDE_PROXY_SCRIPT_GZ_B64:-}" ]]; then
  log "Starting agent governance proxy..."
  if [[ -f /usr/local/bin/rde-start-proxy.sh ]]; then
    # shellcheck disable=SC1091
    source /usr/local/bin/rde-start-proxy.sh
    log "Governance proxy started on port 8877"
  else
    log_error "rde-start-proxy.sh not found — proxy not started"
  fi
else
  log "No governance proxy configured (RDE_PROXY_SCRIPT_GZ_B64 not set)"
fi

# ── Step 2: Run the autonomous agent flow ────────────────────────────────────

log "Starting autonomous agent run..."
exec /usr/local/bin/agent-run.sh
