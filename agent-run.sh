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
# Environment variables are injected by the RDE Portal's autonomous runner.
# Repo config uses REPO_* env vars (REPO_COUNT, REPO_1_URL, REPO_1_BRANCH,
# REPO_1_TOKEN, etc.) set at blueprint creation time by the wizard.
# (see docs/superpowers/specs/2026-06-06-autonomous-agent-blueprint-wizard-design.md).
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

# Git repo config (multi-repo via REPO_* env vars)
REPO_COUNT="${REPO_COUNT:-0}"

# Backward compat: if REPO_COUNT is 0, try legacy env var names
if [[ "$REPO_COUNT" -eq 0 && -n "${BLUEPRINT_GIT_REPOSITORY:-}" ]]; then
  REPO_COUNT=1
  REPO_1_URL="$BLUEPRINT_GIT_REPOSITORY"
  REPO_1_BRANCH="${REPO_BRANCH:-main}"
  REPO_1_TOKEN="${BLUEPRINT_GIT_TOKEN:-}"
fi

if [[ "$REPO_COUNT" -eq 0 ]]; then
  log_error "No repositories configured (REPO_COUNT=0 and no REPO_1_URL or BLUEPRINT_GIT_REPOSITORY set)"
  post_callback "failed" "" "No git repos configured"
  exit 1
fi

# Resolve flat aliases (REPO_URL → REPO_1_URL) if only the flat form was set
REPO_1_URL="${REPO_1_URL:-${REPO_URL:-}}"
REPO_1_BRANCH="${REPO_1_BRANCH:-${REPO_BRANCH:-main}}"
REPO_1_TOKEN="${REPO_1_TOKEN:-${REPO_TOKEN:-}}"

if [[ -z "$REPO_1_URL" ]]; then
  log_error "REPO_1_URL is empty — no repository to clone"
  post_callback "failed" "" "Missing git repo URL"
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

# ── Step 2: Clone repo(s) + create branch ────────────────────────────────────

BRANCH_SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40)
BRANCH="agent/${LINEAR_ISSUE_KEY}-${BRANCH_SLUG}"

log "Cloning $REPO_COUNT repo(s)..."

for i in $(seq 1 "$REPO_COUNT"); do
  url_var="REPO_${i}_URL"; branch_var="REPO_${i}_BRANCH"; token_var="REPO_${i}_TOKEN"
  repo_url="${!url_var:-}"; repo_branch="${!branch_var:-main}"; repo_token="${!token_var:-}"

  if [[ -z "$repo_url" ]]; then
    log "REPO_${i}_URL is empty, skipping."
    continue
  fi

  repo_name=$(basename "$repo_url" .git)
  dest="/repos/${repo_name}"
  provider=$(detect_git_provider "$repo_url")

  log "Cloning repo $i: $repo_url (branch: $repo_branch) -> $dest"

  if ! clone_repo "$repo_url" "$repo_token" "$provider" "$dest" "$repo_branch"; then
    log_error "Failed to clone repository $i: $repo_url"
    post_callback "failed" "" "Failed to clone repository $i"
    exit 1
  fi

  # Configure git identity and create agent branch
  cd "$dest"
  git config user.name "Qovery Autonomous Agent"
  git config user.email "${RDE_OWNER_EMAIL:-autonomous-agent@qovery.com}"

  if ! git checkout -b "$BRANCH"; then
    log_error "Failed to create branch: $BRANCH"
    post_callback "failed" "" "Failed to create branch"
    exit 1
  fi

  cd /
done

# Set working directory
if [[ "$REPO_COUNT" -eq 1 ]]; then
  WORK_DIR="/repos/$(basename "${REPO_1_URL}" .git)"
else
  WORK_DIR="/repos"
fi
cd "$WORK_DIR"

log "Working on branch: $BRANCH (in $WORK_DIR)"

# ── Step 3: Run the AI agent ─────────────────────────────────────────────────

AGENT_USER="coder"
AGENT_LOG="/tmp/agent-output.log"
: > "$AGENT_LOG"

# Hand ownership to the coder user (Claude SDK refuses root)
chown -R "$AGENT_USER:$AGENT_USER" /repos
chown "$AGENT_USER:$AGENT_USER" "$TASK_FILE"

# Fix git safe.directory (repo cloned by root, now owned by coder)
git config --system --add safe.directory '*'

# Ensure coder's home is writable (needed for Claude config)
chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER"

# Derive progress URL from callback URL
PROGRESS_URL="${RDE_RUN_CALLBACK_URL%/result}/progress"

log "Running ${RDE_AUTONOMOUS_AGENT} agent as $AGENT_USER (timeout: ${RDE_RUN_TIMEOUT_MIN}m)..."

AGENT_EXIT=0

case "$RDE_AUTONOMOUS_AGENT" in
  claude)
    # ── Claude Agent SDK execution ─────────────────────────────────────────
    # Uses @anthropic-ai/claude-agent-sdk for programmatic streaming.
    # Events stream in real-time (no pipe buffering) and are forwarded
    # to stdout (container logs) and BFF /progress (Linear agent session).
    timeout "${RDE_RUN_TIMEOUT_MIN}m" runuser -u "$AGENT_USER" -- \
      env TASK_FILE="$TASK_FILE" PROGRESS_URL="$PROGRESS_URL" WORK_DIR="$WORK_DIR" \
      node /usr/local/lib/agent/claude-runner.js 2>&1 | tee -a "$AGENT_LOG" || AGENT_EXIT=${PIPESTATUS[0]}
    AGENT_TAIL=$(tail -10 "$AGENT_LOG" 2>/dev/null | head -c 500 || true)
    ;;
  opencode)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" runuser -u "$AGENT_USER" -- \
      opencode run "$(cat "$TASK_FILE")" 2>&1 | tee -a "$AGENT_LOG" || AGENT_EXIT=${PIPESTATUS[0]}
    AGENT_TAIL=$(tail -10 "$AGENT_LOG" 2>/dev/null | head -c 500 || true)
    ;;
  codex)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" runuser -u "$AGENT_USER" -- \
      codex --full-auto "$(cat "$TASK_FILE")" 2>&1 | tee -a "$AGENT_LOG" || AGENT_EXIT=${PIPESTATUS[0]}
    AGENT_TAIL=$(tail -10 "$AGENT_LOG" 2>/dev/null | head -c 500 || true)
    ;;
  gemini)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" runuser -u "$AGENT_USER" -- \
      gemini -p "$(cat "$TASK_FILE")" 2>&1 | tee -a "$AGENT_LOG" || AGENT_EXIT=${PIPESTATUS[0]}
    AGENT_TAIL=$(tail -10 "$AGENT_LOG" 2>/dev/null | head -c 500 || true)
    ;;
  cursor)
    timeout "${RDE_RUN_TIMEOUT_MIN}m" runuser -u "$AGENT_USER" -- \
      cursor-agent "$(cat "$TASK_FILE")" 2>&1 | tee -a "$AGENT_LOG" || AGENT_EXIT=${PIPESTATUS[0]}
    AGENT_TAIL=$(tail -10 "$AGENT_LOG" 2>/dev/null | head -c 500 || true)
    ;;
  *)
    log_error "Unknown agent: $RDE_AUTONOMOUS_AGENT"
    post_callback "failed" "" "Unknown agent: $RDE_AUTONOMOUS_AGENT"
    exit 1
    ;;
esac

# Check for timeout (exit code 124)
if [[ "$AGENT_EXIT" -eq 124 ]]; then
  log_error "Agent timed out after ${RDE_RUN_TIMEOUT_MIN} minutes"
  post_callback "timed_out" "" "Agent timed out after ${RDE_RUN_TIMEOUT_MIN}m"
  exit 1
fi

# Check for agent failure
if [[ "$AGENT_EXIT" -ne 0 ]]; then
  log_error "Agent exited with code $AGENT_EXIT"
  REASON="Agent exited with code $AGENT_EXIT"
  if [[ -n "${AGENT_TAIL:-}" ]]; then
    REASON="${REASON}. Last output: ${AGENT_TAIL}"
  fi
  post_callback "failed" "" "$REASON"
  exit 1
fi

log "Agent completed successfully"

# ── Step 4: Check for changes, commit, push, and open PRs ────────────────────

PR_TITLE="${LINEAR_ISSUE_KEY}: ${ISSUE_TITLE}"
PR_BODY="Automated fix by the Qovery autonomous agent for [${LINEAR_ISSUE_KEY}](https://linear.app/issue/${LINEAR_ISSUE_ID}).

$(cat "$TASK_FILE")"

ANY_CHANGES=false
PR_URLS=()

for i in $(seq 1 "$REPO_COUNT"); do
  url_var="REPO_${i}_URL"; token_var="REPO_${i}_TOKEN"
  repo_url="${!url_var:-}"; repo_token="${!token_var:-}"

  if [[ -z "$repo_url" ]]; then
    continue
  fi

  repo_name=$(basename "$repo_url" .git)
  dest="/repos/${repo_name}"
  provider=$(detect_git_provider "$repo_url")

  cd "$dest"

  # Check for changes in this repo
  if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    log "No changes in repo $i ($repo_name), skipping."
    continue
  fi

  ANY_CHANGES=true
  log "Committing and pushing changes in repo $i ($repo_name)..."

  git add -A
  git commit -m "agent: ${LINEAR_ISSUE_KEY} — ${ISSUE_TITLE}"

  if ! push_branch "$repo_url" "$repo_token" "$provider" "$BRANCH"; then
    log_error "Failed to push branch in repo $i ($repo_name)"
    post_callback "failed" "" "Failed to push branch in repo $repo_name"
    exit 1
  fi

  log "Pushed branch: $BRANCH to $repo_name"

  # Open PR
  log "Opening pull request for $repo_name..."
  pr_url=$(create_pr "$repo_url" "$repo_token" "$provider" "$BRANCH" "$PR_TITLE" "$PR_BODY")

  if [[ -n "$pr_url" ]]; then
    log "PR created: $pr_url"
    PR_URLS+=("$pr_url")
  else
    log "Warning: push succeeded but PR creation failed for $repo_name"
  fi

  cd /
done

if [[ "$ANY_CHANGES" == false ]]; then
  log "No changes made by the agent — nothing to push"
  post_callback "failed" "" "Agent made no code changes"
  exit 0
fi

# ── Step 5: Call back the BFF ────────────────────────────────────────────────
# The BFF callback handler posts Linear comments, emits agent activities,
# and manages issue state transitions — no need to duplicate that here.

# Report the first PR URL (primary repo) to the callback
FIRST_PR="${PR_URLS[0]:-}"

if [[ -n "$FIRST_PR" ]]; then
  post_callback "pr_opened" "$FIRST_PR" ""
  log "Done. PR: $FIRST_PR"
else
  post_callback "failed" "" "Push succeeded but PR creation failed"
  log "Done. Changes pushed but PR creation failed."
fi

exit 0
