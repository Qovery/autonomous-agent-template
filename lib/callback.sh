#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# BFF callback helper for the autonomous agent
#
# Posts the run result to the RDE Portal's callback endpoint.
# Retries on failure (3 attempts, 5s between retries) so a transient network
# issue doesn't orphan the run. The callback is idempotent on the BFF side.
# ────────────────────────────────────────────────────────────────────────────────

# Post the result to the BFF callback URL.
# Usage: post_callback <status> [pr_url] [failure_reason]
#   status: "pr_opened" | "failed" | "timed_out"
post_callback() {
  local status="$1"
  local pr_url="${2:-}"
  local failure_reason="${3:-}"

  local callback_url="${RDE_RUN_CALLBACK_URL:-}"
  if [[ -z "$callback_url" ]]; then
    printf '[callback] [ERROR] RDE_RUN_CALLBACK_URL not set — cannot report result\n' >&2
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg status "$status" \
    --arg pr_url "$pr_url" \
    --arg failure_reason "$failure_reason" \
    '{
      status: $status,
      pr_url: (if $pr_url == "" then null else $pr_url end),
      failure_reason: (if $failure_reason == "" then null else $failure_reason end)
    }')

  local attempt max_attempts=3 delay=5
  for attempt in $(seq 1 $max_attempts); do
    local http_code
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
      "$callback_url" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null) || true

    if [[ "$http_code" =~ ^2 ]]; then
      printf '[callback] Result posted: status=%s (HTTP %s)\n' "$status" "$http_code"
      return 0
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      printf '[callback] Attempt %d/%d failed (HTTP %s), retrying in %ds...\n' \
        "$attempt" "$max_attempts" "$http_code" "$delay" >&2
      sleep "$delay"
    fi
  done

  printf '[callback] [ERROR] Failed to post result after %d attempts\n' "$max_attempts" >&2
  return 1
}
