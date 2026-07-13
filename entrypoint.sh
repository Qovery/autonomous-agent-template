#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Qovery Autonomous Agent — Entrypoint
#
# This is a self-contained entrypoint for autonomous agent workspaces.
# It starts the governance proxy (if configured), then runs the provider's
# agent-run.sh which performs the full autonomous cycle:
#   fetch issue -> clone repo -> run AI agent -> push -> PR -> callback
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

# ── Step 2: Select the ticket provider ───────────────────────────────────────
# Auto-detect from the injected env vars, unless RDE_TICKET_PROVIDER overrides.

PROVIDER="${RDE_TICKET_PROVIDER:-}"
if [[ -z "$PROVIDER" ]]; then
  if [[ -n "${JIRA_ISSUE_KEY:-}${JIRA_BASE_URL:-}" ]]; then
    PROVIDER=jira
  elif [[ -n "${LINEAR_ISSUE_ID:-}${LINEAR_ISSUE_KEY:-}" ]]; then
    PROVIDER=linear
  fi
fi

if [[ -z "$PROVIDER" ]]; then
  log_error "No ticket provider env vars set (expected JIRA_* or LINEAR_*)"
  exit 1
fi

AGENT_RUN="/usr/local/lib/agent/${PROVIDER}/agent-run.sh"
if [[ ! -x "$AGENT_RUN" ]]; then
  log_error "Unknown ticket provider '$PROVIDER' — $AGENT_RUN not found"
  exit 1
fi

# ── Step 3: Run the autonomous agent flow ─────────────────────────────────────

log "Starting autonomous agent run (provider: $PROVIDER)..."
exec "$AGENT_RUN"
