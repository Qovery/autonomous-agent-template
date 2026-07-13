#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Jira Cloud API helpers for the autonomous agent
#
# Uses the REST v2 API (plaintext description/comment bodies — v3 returns ADF
# JSON which is impractical to parse in bash). Auth is HTTP Basic with the
# account email + API token.
# ────────────────────────────────────────────────────────────────────────────────

# Base URL without a trailing slash, e.g. https://your-org.atlassian.net
JIRA_URL="${JIRA_BASE_URL%/}/rest/api/2"

# Fetch a Jira issue's summary + description (+ comments) and write to a file.
# Usage: fetch_jira_issue <issue_key> <output_file>
fetch_jira_issue() {
  local issue_key="$1"
  local output_file="$2"

  local response
  response=$(curl -sS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Accept: application/json" \
    "${JIRA_URL}/issue/${issue_key}?fields=summary,description,comment")

  local title description
  title=$(echo "$response" | jq -r '.fields.summary // empty')
  description=$(echo "$response" | jq -r '.fields.description // empty')

  if [[ -z "$title" ]]; then
    return 1
  fi

  {
    echo "# ${title}"
    echo ""
    if [[ -n "$description" ]]; then
      echo "$description"
      echo ""
    fi
    # Append existing comments for extra context
    local comments
    comments=$(echo "$response" | jq -r '.fields.comment.comments[]?.body // empty' 2>/dev/null)
    if [[ -n "$comments" ]]; then
      echo "---"
      echo "## Additional context from comments"
      echo ""
      echo "$comments"
    fi
  } > "$output_file"

  return 0
}

# Post a comment on a Jira issue. Best-effort — does not exit on failure.
# Usage: jira_comment <issue_key> <body>
jira_comment() {
  local issue_key="$1"
  local body="$2"

  curl -sS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${JIRA_URL}/issue/${issue_key}/comment" \
    -d "$(jq -n --arg body "$body" '{ body: $body }')" > /dev/null 2>&1 || true
}

# Transition a Jira issue to a workflow state.
# Usage: jira_set_state <issue_key> <transition_id>
jira_set_state() {
  local issue_key="$1"
  local transition_id="$2"

  curl -sS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${JIRA_URL}/issue/${issue_key}/transitions" \
    -d "$(jq -n --arg id "$transition_id" '{ transition: { id: $id } }')" > /dev/null 2>&1 || true
}
