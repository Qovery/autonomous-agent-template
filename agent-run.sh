#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Qovery Autonomous Agent — Main Run Script
#
# Performs the full autonomous cycle:
#   1. Fetch the Linear issue
#   2. Clone the repo + create a branch
#   3. Run the AI agent headless (Claude Code / OpenCode / Codex / Gemini / Cursor)
#   4. Commit + push + open a PR
#   5. Comment the PR link on the Linear issue
#   6. Call back the BFF with the result
#
# Environment variables are injected by the RDE Portal's autonomous runner
# (see docs/superpowers/specs/2026-06-04-agent-run-entrypoint.md for the full contract).
# ────────────────────────────────────────────────────────────────────────────────
set -uo pipefail  # no -e: we handle errors explicitly per step

# ── Load helpers ─────────────────────────────────────────────────────────────
SCRIPT_DIR=/usr/local/lib/agent
# shellcheck disable=SC1091
source "$SCRIPT_DIR/linear.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/git-pr.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/callback.sh"

log() { printf '[agent-run] %s\n' "$1"; }
log_error() { printf '[agent-run] [ERROR] %s\n' "$1" >&2; }

# ── Validate required environment ────────────────────────────────────────────

REQUIRED_VARS=(
  LINEAR_API_TOKEN LINEAR_ISSUE_ID LINEAR_ISSUE_KEY
  RDE_AUTONOMOUS_AGENT RDE_RUN_CALLBACK_URL RDE_RUN_TIMEOUT_MIN
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    log_error "Missing required environment variable: $var"
    post_callback "failed" "" "Missing env var: $var"
    exit 1
  fi
done

# Git config (from blueprint publish settings)
GIT_REPO="${BLUEPRINT_GIT_REPOSITORY:-}"
GIT_TOKEN="${BLUEPRINT_GIT_TOKEN:-}"
GIT_PROVIDER="${BLUEPRINT_GIT_PROVIDER:-github}"

if [[ -z "$GIT_REPO" || -z "$GIT_TOKEN" ]]; then
  log_error "Missing BLUEPRINT_GIT_REPOSITORY or BLUEPRINT_GIT_TOKEN"
  linear_comment "$LINEAR_ISSUE_ID" "❌ **Agent failed:** Git repository or token not configured on the blueprint."
  post_callback "failed" "" "Missing git repo/token configuration"
  exit 1
fi

# ── Step 1: Fetch the Linear issue ───────────────────────────────────────────

log "Fetching Linear issue ${LINEAR_ISSUE_KEY}..."
TASK_FILE="/tmp/task.md"

if ! fetch_issue "$LINEAR_ISSUE_ID" "$TASK_FILE"; then
  log_error "Failed to fetch Linear issue"
  post_callback "failed" "" "Failed to fetch Linear issue"
  exit 1
fi

ISSUE_TITLE=$(head -1 "$TASK_FILE" | sed 's/^# //')
log "Issue: ${LINEAR_ISSUE_KEY} — ${ISSUE_TITLE}"

# ── Step 2: Clone the repo + create branch ───────────────────────────────────

log "Cloning repository..."
WORK_DIR="/home/coder/project/repo"
BRANCH_SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40)
BRANCH="agent/${LINEAR_ISSUE_KEY}-${BRANCH_SLUG}"

if ! clone_repo "$GIT_REPO" "$GIT_TOKEN" "$GIT_PROVIDER" "$WORK_DIR"; then
  log_error "Failed to clone repository"
  linear_comment "$LINEAR_ISSUE_ID" "❌ **Agent failed:** Could not clone the repository."
  post_callback "failed" "" "Failed to clone repository"
  exit 1
fi

cd "$WORK_DIR"

if ! git checkout -b "$BRANCH"; then
  log_error "Failed to create branch: $BRANCH"
  linear_comment "$LINEAR_ISSUE_ID" "❌ **Agent failed:** Could not create branch \`$BRANCH\`."
  post_callback "failed" "" "Failed to create branch"
  exit 1
fi

log "Working on branch: $BRANCH"

# ── Step 3: Run the AI agent headless ────────────────────────────────────────

log "Running ${RDE_AUTONOMOUS_AGENT} agent (timeout: ${RDE_RUN_TIMEOUT_MIN}m)..."

AGENT_EXIT=0
case "$RDE_AUTONOMOUS_AGENT" in
  claude)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" claude -p "$(cat "$TASK_FILE")" || AGENT_EXIT=$?
    ;;
  opencode)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" opencode run "$(cat "$TASK_FILE")" || AGENT_EXIT=$?
    ;;
  codex)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" codex --full-auto "$(cat "$TASK_FILE")" || AGENT_EXIT=$?
    ;;
  gemini)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" gemini -p "$(cat "$TASK_FILE")" || AGENT_EXIT=$?
    ;;
  cursor)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" cursor-agent "$(cat "$TASK_FILE")" || AGENT_EXIT=$?
    ;;
  *)
    log_error "Unknown agent: $RDE_AUTONOMOUS_AGENT"
    linear_comment "$LINEAR_ISSUE_ID" "❌ **Agent failed:** Unknown agent type \`$RDE_AUTONOMOUS_AGENT\`."
    post_callback "failed" "" "Unknown agent: $RDE_AUTONOMOUS_AGENT"
    exit 1
    ;;
esac

# Check for timeout (exit code 124)
if [[ "$AGENT_EXIT" -eq 124 ]]; then
  log_error "Agent timed out after ${RDE_RUN_TIMEOUT_MIN} minutes"
  linear_comment "$LINEAR_ISSUE_ID" "⏱ **Agent timed out** after ${RDE_RUN_TIMEOUT_MIN} minutes."
  if [[ -n "${RDE_LINEAR_STATE_FAILED_ID:-}" ]]; then
    linear_set_state "$LINEAR_ISSUE_ID" "$RDE_LINEAR_STATE_FAILED_ID"
  fi
  post_callback "timed_out" "" ""
  exit 1
fi

# Check for agent failure
if [[ "$AGENT_EXIT" -ne 0 ]]; then
  log_error "Agent exited with code $AGENT_EXIT"
  linear_comment "$LINEAR_ISSUE_ID" "❌ **Agent failed** with exit code $AGENT_EXIT."
  if [[ -n "${RDE_LINEAR_STATE_FAILED_ID:-}" ]]; then
    linear_set_state "$LINEAR_ISSUE_ID" "$RDE_LINEAR_STATE_FAILED_ID"
  fi
  post_callback "failed" "" "Agent exited with code $AGENT_EXIT"
  exit 1
fi

log "Agent completed successfully"

# ── Step 4: Check for changes, commit, and push ─────────────────────────────

if git diff --quiet && git diff --cached --quiet; then
  log "No changes made by the agent — nothing to push"
  linear_comment "$LINEAR_ISSUE_ID" "ℹ️ **Agent completed** but made no code changes."
  post_callback "failed" "" "Agent made no code changes"
  exit 0
fi

log "Committing and pushing changes..."

git add -A
git commit -m "agent: ${LINEAR_ISSUE_KEY} — ${ISSUE_TITLE}"

if ! push_branch "$GIT_REPO" "$GIT_TOKEN" "$GIT_PROVIDER" "$BRANCH"; then
  log_error "Failed to push branch"
  linear_comment "$LINEAR_ISSUE_ID" "❌ **Agent failed:** Could not push branch \`$BRANCH\`."
  post_callback "failed" "" "Failed to push branch"
  exit 1
fi

log "Pushed branch: $BRANCH"

# ── Step 5: Open a PR ───────────────────────────────────────────────────────

log "Opening pull request..."

PR_TITLE="${LINEAR_ISSUE_KEY}: ${ISSUE_TITLE}"
PR_BODY="Automated fix by the Qovery autonomous agent for [${LINEAR_ISSUE_KEY}](https://linear.app/issue/${LINEAR_ISSUE_ID}).

$(cat "$TASK_FILE")"

PR_URL=""
PR_URL=$(create_pr "$GIT_REPO" "$GIT_TOKEN" "$GIT_PROVIDER" "$BRANCH" "$PR_TITLE" "$PR_BODY")

if [[ -z "$PR_URL" ]]; then
  log_error "Failed to create PR (push succeeded, PR creation failed)"
  linear_comment "$LINEAR_ISSUE_ID" "⚠️ **Agent pushed branch** \`$BRANCH\` but failed to create a PR. Please create it manually."
  post_callback "failed" "" "Push succeeded but PR creation failed"
  exit 1
fi

log "PR created: $PR_URL"

# ── Step 6: Update Linear issue ──────────────────────────────────────────────

linear_comment "$LINEAR_ISSUE_ID" "✅ **Agent complete** — PR opened: [View pull request](${PR_URL})"

if [[ -n "${RDE_LINEAR_STATE_REVIEW_ID:-}" ]]; then
  linear_set_state "$LINEAR_ISSUE_ID" "$RDE_LINEAR_STATE_REVIEW_ID"
fi

# ── Step 7: Call back the BFF ────────────────────────────────────────────────

post_callback "pr_opened" "$PR_URL" ""

log "Done. PR: $PR_URL"
exit 0
