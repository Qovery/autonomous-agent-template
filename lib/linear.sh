#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Linear API helpers for the autonomous agent
# ────────────────────────────────────────────────────────────────────────────────

LINEAR_API="https://api.linear.app/graphql"

# Fetch a Linear issue's title + description and write to a file.
# Usage: fetch_issue <issue_id> <output_file>
fetch_issue() {
  local issue_id="$1"
  local output_file="$2"

  local response
  response=$(curl -sS "$LINEAR_API" \
    -H "Authorization: ${LINEAR_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$issue_id" '{
      query: "query($id: String!) { issue(id: $id) { identifier title description comments { nodes { body } } } }",
      variables: { id: $id }
    }')")

  local title description
  title=$(echo "$response" | jq -r '.data.issue.title // empty')
  description=$(echo "$response" | jq -r '.data.issue.description // empty')

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
    comments=$(echo "$response" | jq -r '.data.issue.comments.nodes[]?.body // empty' 2>/dev/null)
    if [[ -n "$comments" ]]; then
      echo "---"
      echo "## Additional context from comments"
      echo ""
      echo "$comments"
    fi
  } > "$output_file"

  return 0
}

# Post a comment on a Linear issue. Best-effort — does not exit on failure.
# Usage: linear_comment <issue_id> <body>
linear_comment() {
  local issue_id="$1"
  local body="$2"

  curl -sS "$LINEAR_API" \
    -H "Authorization: ${LINEAR_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$issue_id" --arg body "$body" '{
      query: "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }",
      variables: { issueId: $id, body: $body }
    }')" > /dev/null 2>&1 || true
}

# Transition a Linear issue to a workflow state.
# Usage: linear_set_state <issue_id> <state_id>
linear_set_state() {
  local issue_id="$1"
  local state_id="$2"

  curl -sS "$LINEAR_API" \
    -H "Authorization: ${LINEAR_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$issue_id" --arg stateId "$state_id" '{
      query: "mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }",
      variables: { id: $id, stateId: $stateId }
    }')" > /dev/null 2>&1 || true
}
