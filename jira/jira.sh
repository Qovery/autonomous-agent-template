#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Jira Cloud API helpers for the autonomous agent
#
# Auth: OAuth 2.0 access token (Bearer). JIRA_BASE_URL is the pre-computed API
# base injected by the Portal — it already includes the gateway, cloud id, and
# version, e.g. https://api.atlassian.com/ex/jira/<cloud_id>/rest/api/3/ — so we
# just append the resource path. Uses REST v3, whose text fields (description,
# comment bodies) are Atlassian Document Format (ADF) JSON — flattened to plain
# text below with a jq walker.
# ────────────────────────────────────────────────────────────────────────────────

JIRA_URL="${JIRA_BASE_URL%/}"

# jq definition that flattens an ADF node tree to plain text. Text lives in
# `{type:"text", text:"..."}` leaves; block nodes (paragraph, heading, list
# item, …) get a trailing newline so structure survives. Reused across queries.
ADF_TO_TEXT='def adf_text:
  if type == "object" then
    if .type == "text" then (.text // "")
    elif .type == "hardBreak" then "\n"
    else ((.content // []) | map(adf_text) | join(""))
         + (if ((.type // "") | test("^(paragraph|heading|blockquote|codeBlock|listItem|rule|tableRow)$")) then "\n" else "" end)
    end
  elif type == "array" then (map(adf_text) | join(""))
  else "" end;'

# Fetch a Jira issue's summary + description (+ comments) and write to a file.
# Usage: fetch_jira_issue <issue_key> <output_file>
fetch_jira_issue() {
  local issue_key="$1"
  local output_file="$2"

  local response
  response=$(curl -sS \
    -H "Authorization: Bearer ${JIRA_ACCESS_TOKEN}" \
    -H "Accept: application/json" \
    "${JIRA_URL}/issue/${issue_key}?fields=summary,description,comment")

  local title description
  title=$(echo "$response" | jq -r '.fields.summary // empty')
  description=$(echo "$response" | jq -r "${ADF_TO_TEXT} .fields.description // {} | adf_text | rtrimstr(\"\n\")")

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
    comments=$(echo "$response" | jq -r "${ADF_TO_TEXT} [.fields.comment.comments[]?.body | adf_text | rtrimstr(\"\n\")] | join(\"\n\n\")" 2>/dev/null)
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
# v3 requires the comment body as an ADF document, so wrap the plaintext.
# Usage: jira_comment <issue_key> <body>
jira_comment() {
  local issue_key="$1"
  local body="$2"

  curl -sS \
    -H "Authorization: Bearer ${JIRA_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${JIRA_URL}/issue/${issue_key}/comment" \
    -d "$(jq -n --arg body "$body" '{
      body: {
        type: "doc", version: 1,
        content: [ { type: "paragraph", content: [ { type: "text", text: $body } ] } ]
      }
    }')" > /dev/null 2>&1 || true
}

# Transition a Jira issue to a workflow state.
# Usage: jira_set_state <issue_key> <transition_id>
jira_set_state() {
  local issue_key="$1"
  local transition_id="$2"

  curl -sS \
    -H "Authorization: Bearer ${JIRA_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${JIRA_URL}/issue/${issue_key}/transitions" \
    -d "$(jq -n --arg id "$transition_id" '{ transition: { id: $id } }')" > /dev/null 2>&1 || true
}
