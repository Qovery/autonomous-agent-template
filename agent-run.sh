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
SCREEN_DUMP="/tmp/agent-screen.txt"
SCREEN_PREV="/tmp/agent-screen-prev.txt"
: > "$AGENT_LOG"
: > "$SCREEN_DUMP"
: > "$SCREEN_PREV"

# Hand ownership to the coder user (Claude refuses root)
chown -R "$AGENT_USER:$AGENT_USER" /repos
chown "$AGENT_USER:$AGENT_USER" "$TASK_FILE"

# Fix git safe.directory (repo cloned by root, now owned by coder)
git config --system --add safe.directory '*'

# Ensure coder's home is writable (needed for Claude config + Zellij socket)
chown -R "$AGENT_USER:$AGENT_USER" "/home/$AGENT_USER"

# Derive progress URL from callback URL
PROGRESS_URL="${RDE_RUN_CALLBACK_URL%/result}/progress"

# Helper: post a progress message to BFF -> Linear agent session
_post_progress() {
  local msg="$1"
  log "Agent: $msg"
  curl -s -m 5 "$PROGRESS_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$msg" '{message: $m}')" > /dev/null 2>&1 || true
}

log "Running ${RDE_AUTONOMOUS_AGENT} agent as $AGENT_USER (timeout: ${RDE_RUN_TIMEOUT_MIN}m)..."

AGENT_EXIT=0

case "$RDE_AUTONOMOUS_AGENT" in
  claude)
    # ── Zellij-based interactive Claude execution ──────────────────────────
    # Runs Claude interactively inside a Zellij session exposed via ttyd.
    # Benefits:
    #   - Real-time output (terminal = line buffered, no pipe buffering)
    #   - Live view in the RDE dashboard (ttyd on port 7681)
    #   - Human can attach and take over at any time
    #   - Progress streamed to Linear via dump-screen diffs

    # Pre-configure Claude Code to skip auth prompts
    CLAUDE_DIR="/home/$AGENT_USER/.claude"
    mkdir -p "$CLAUDE_DIR"
    cat > "$CLAUDE_DIR/settings.json" <<'CSET'
{
  "permissions": {
    "allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)", "WebFetch(*)"],
    "deny": []
  }
}
CSET
    chown -R "$AGENT_USER:$AGENT_USER" "$CLAUDE_DIR"

    # Claude wrapper: runs with --dangerously-skip-permissions and exits when done
    CLAUDE_WRAPPER="/tmp/run-claude.sh"
    cat > "$CLAUDE_WRAPPER" <<'CWEOF'
#!/bin/bash
exec claude --dangerously-skip-permissions
CWEOF
    chmod +x "$CLAUDE_WRAPPER"
    chown "$AGENT_USER:$AGENT_USER" "$CLAUDE_WRAPPER"

    # Zellij config: Claude as the default shell, minimal chrome
    ZELLIJ_CFG="/tmp/.zellij-agent.kdl"
    cat > "$ZELLIJ_CFG" <<ZELEOF
simplified_ui true
pane_frames false
default_layout "compact"
default_shell "$CLAUDE_WRAPPER"
show_release_notes false
show_startup_tips false
mouse_mode false
ZELEOF
    chown "$AGENT_USER:$AGENT_USER" "$ZELLIJ_CFG"

    # Start ttyd -> Zellij -> Claude on port 7681 (matchable by RDE dashboard)
    log "Starting Zellij session with Claude (ttyd on port 7681)..."
    runuser -u "$AGENT_USER" -- bash -c "
      cd '$WORK_DIR' && \
      ZELLIJ_CONFIG_FILE='$ZELLIJ_CFG' \
      ttyd -W -p 7681 zellij --session agent 2>/dev/null
    " &
    TTYD_PID=$!

    # Wait for Claude to initialize inside Zellij
    log "Waiting for Claude to initialize..."
    CLAUDE_READY=false
    for attempt in $(seq 1 30); do
      sleep 2

      # Check if ttyd process died
      if ! kill -0 "$TTYD_PID" 2>/dev/null; then
        log_error "ttyd/Zellij exited unexpectedly"
        break
      fi

      # Dump screen to see what Claude is showing
      runuser -u "$AGENT_USER" -- \
        zellij --session agent action dump-screen "$SCREEN_DUMP" 2>/dev/null || continue

      # Auto-accept any y/n confirmation prompts (API key, terms, etc.)
      if grep -qiE 'y/n|yes/no|confirm|accept' "$SCREEN_DUMP" 2>/dev/null; then
        log "Auto-accepting prompt..."
        runuser -u "$AGENT_USER" -- \
          zellij --session agent action write-chars $'y\n' 2>/dev/null || true
        sleep 2
        continue
      fi

      # Check if Claude's interactive prompt is ready (❯ or > character)
      if grep -qE '❯|>' "$SCREEN_DUMP" 2>/dev/null; then
        CLAUDE_READY=true
        log "Claude is ready"
        break
      fi
    done

    if [[ "$CLAUDE_READY" != true ]]; then
      log_error "Claude failed to initialize within 60 seconds"
      kill "$TTYD_PID" 2>/dev/null
      post_callback "failed" "" "Claude failed to initialize"
      exit 1
    fi

    _post_progress "Claude initialized. Sending task..."

    # Inject the task prompt
    # Use a file reference to avoid multi-line input issues with write-chars
    runuser -u "$AGENT_USER" -- \
      zellij --session agent action write-chars \
      $'Read the task in /tmp/task.md and implement it completely. When you are done with all changes, type exit to finish.\n' 2>/dev/null

    _post_progress "Task sent. Agent is working..."

    # ── Monitor progress via dump-screen diffs ───────────────────────────
    DEADLINE=$((SECONDS + RDE_RUN_TIMEOUT_MIN * 60))
    HEARTBEAT_NEXT=$((SECONDS + 120))

    while true; do
      sleep 10

      # Check timeout
      if [[ $SECONDS -ge $DEADLINE ]]; then
        log_error "Agent timed out after ${RDE_RUN_TIMEOUT_MIN} minutes"
        kill "$TTYD_PID" 2>/dev/null
        AGENT_EXIT=124
        break
      fi

      # Check if Zellij session is still alive
      if ! runuser -u "$AGENT_USER" -- zellij list-sessions 2>/dev/null | grep -q agent; then
        log "Zellij session ended — Claude finished"
        AGENT_EXIT=0
        break
      fi

      # Check if ttyd died
      if ! kill -0 "$TTYD_PID" 2>/dev/null; then
        log "ttyd process ended"
        AGENT_EXIT=0
        break
      fi

      # Dump screen and diff for progress
      cp "$SCREEN_DUMP" "$SCREEN_PREV" 2>/dev/null || true
      runuser -u "$AGENT_USER" -- \
        zellij --session agent action dump-screen "$SCREEN_DUMP" 2>/dev/null || true

      # Extract new lines (lines in new dump not in previous)
      NEW_LINES=$(diff "$SCREEN_PREV" "$SCREEN_DUMP" 2>/dev/null | grep '^>' | sed 's/^> //' | head -5)
      if [[ -n "$NEW_LINES" ]]; then
        # Forward the first meaningful new line as progress
        PROGRESS_LINE=$(echo "$NEW_LINES" | grep -vE '^\s*$|^─|^│|^┌|^└|^├' | head -1 | head -c 200)
        if [[ -n "$PROGRESS_LINE" ]]; then
          _post_progress "$PROGRESS_LINE"
        fi
      fi

      # Heartbeat
      if [[ $SECONDS -ge $HEARTBEAT_NEXT ]]; then
        local elapsed=$(( (SECONDS - (DEADLINE - RDE_RUN_TIMEOUT_MIN * 60)) / 60 ))
        log "Agent still working... (${elapsed}m elapsed)"
        HEARTBEAT_NEXT=$((SECONDS + 120))
      fi
    done

    # Cleanup ttyd/zellij
    kill "$TTYD_PID" 2>/dev/null; wait "$TTYD_PID" 2>/dev/null || true

    # Capture final screen content for diagnostics
    AGENT_TAIL=$(cat "$SCREEN_DUMP" 2>/dev/null | grep -vE '^\s*$' | tail -10 | head -c 500)
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
