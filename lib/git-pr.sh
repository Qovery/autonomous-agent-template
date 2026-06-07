#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Git clone/push + PR creation helpers for the autonomous agent
#
# Mirrors the token-authed URL pattern from rde-portal's git-push.ts:
#   github:    x-access-token:<token>
#   gitlab:    oauth2:<token>
#   bitbucket: x-token-auth:<token>
# ────────────────────────────────────────────────────────────────────────────────

# Detect git provider from a repo URL.
# Usage: detect_git_provider <repo_url>
# Outputs: github | gitlab | bitbucket | unknown
detect_git_provider() {
  local url="$1"
  case "$url" in
    *github.com*)    echo "github" ;;
    *gitlab.com*|*gitlab.*) echo "gitlab" ;;
    *bitbucket.org*) echo "bitbucket" ;;
    *)               echo "github" ;;  # default to github for self-hosted
  esac
}

# Build a token-authed git URL for the given provider.
# Usage: build_authed_url <repo_url> <token> [provider]
#   If provider is omitted, it is auto-detected from the URL.
build_authed_url() {
  local repo_url="$1"
  local token="$2"
  local provider="${3:-$(detect_git_provider "$repo_url")}"

  # Strip any existing auth from the URL and extract components
  local clean_url
  clean_url=$(echo "$repo_url" | sed 's|://[^@]*@|://|')

  local proto host_and_path
  proto=$(echo "$clean_url" | grep -oE '^https?://')
  host_and_path=$(echo "$clean_url" | sed "s|^${proto}||")

  case "$provider" in
    github)    echo "${proto}x-access-token:${token}@${host_and_path}" ;;
    gitlab)    echo "${proto}oauth2:${token}@${host_and_path}" ;;
    bitbucket) echo "${proto}x-token-auth:${token}@${host_and_path}" ;;
    *)         echo "${proto}${token}@${host_and_path}" ;;
  esac
}

# Extract owner/repo from a git URL (works for github.com/gitlab.com URLs).
# Usage: extract_owner_repo <repo_url>
# Outputs: owner/repo (e.g., "Qovery/rde-portal")
extract_owner_repo() {
  local repo_url="$1"
  echo "$repo_url" | sed 's|\.git$||' | sed 's|/$||' | grep -oE '[^/]+/[^/]+$'
}

# Clone a repo with token auth.
# Usage: clone_repo <repo_url> <token> <provider> <dest_dir> [branch]
#   If provider is empty, it is auto-detected from the URL.
clone_repo() {
  local repo_url="$1" token="$2" provider="$3" dest_dir="$4" branch="${5:-}"
  local authed_url
  authed_url=$(build_authed_url "$repo_url" "$token" "$provider")

  # Silence the URL in output (it contains the token)
  if [[ -n "$branch" ]]; then
    git clone --depth 1 --branch "$branch" "$authed_url" "$dest_dir" 2>&1 | grep -v "$token" || true
  else
    git clone --depth 1 "$authed_url" "$dest_dir" 2>&1 | grep -v "$token" || true
  fi

  [[ -d "$dest_dir/.git" ]]
}

# Push the current branch to the remote.
# Usage: push_branch <repo_url> <token> <provider> <branch>
push_branch() {
  local repo_url="$1" token="$2" provider="$3" branch="$4"
  local authed_url
  authed_url=$(build_authed_url "$repo_url" "$token" "$provider")

  # Add a push remote with the token-authed URL
  git remote set-url origin "$authed_url" 2>/dev/null \
    || git remote add push-target "$authed_url" 2>/dev/null

  # Unshallow if needed (shallow clones can't push new branches to some providers)
  git fetch --unshallow origin 2>/dev/null || true

  git push origin "$branch" 2>&1 | grep -v "$token" || true

  # Verify the push succeeded by checking the remote
  git ls-remote --heads origin "$branch" | grep -q "$branch"
}

# Create a pull request / merge request via the provider's REST API.
# Usage: create_pr <repo_url> <token> <provider> <branch> <title> <body>
# Outputs: the PR/MR URL on success, empty string on failure.
create_pr() {
  local repo_url="$1" token="$2" provider="$3" branch="$4" title="$5" body="$6"
  local owner_repo
  owner_repo=$(extract_owner_repo "$repo_url")

  case "$provider" in
    github)
      _create_github_pr "$owner_repo" "$token" "$branch" "$title" "$body"
      ;;
    gitlab)
      _create_gitlab_mr "$owner_repo" "$token" "$branch" "$title" "$body"
      ;;
    *)
      # Bitbucket and others: push only, no PR API
      echo ""
      ;;
  esac
}

# ── GitHub PR ────────────────────────────────────────────────────────────────

_create_github_pr() {
  local owner_repo="$1" token="$2" branch="$3" title="$4" body="$5"
  local response pr_url

  # Try 'main' first
  response=$(curl -sS "https://api.github.com/repos/${owner_repo}/pulls" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$(jq -n --arg title "$title" --arg body "$body" --arg head "$branch" --arg base "main" \
      '{ title: $title, body: $body, head: $head, base: $base }')")

  pr_url=$(echo "$response" | jq -r '.html_url // empty')

  # Retry with 'master' if 'main' failed
  if [[ -z "$pr_url" ]]; then
    response=$(curl -sS "https://api.github.com/repos/${owner_repo}/pulls" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$(jq -n --arg title "$title" --arg body "$body" --arg head "$branch" --arg base "master" \
        '{ title: $title, body: $body, head: $head, base: $base }')")

    pr_url=$(echo "$response" | jq -r '.html_url // empty')
  fi

  echo "$pr_url"
}

# ── GitLab MR ────────────────────────────────────────────────────────────────

_create_gitlab_mr() {
  local owner_repo="$1" token="$2" branch="$3" title="$4" body="$5"
  local encoded_path response mr_url

  encoded_path=$(echo "$owner_repo" | jq -Rr @uri)

  response=$(curl -sS "https://gitlab.com/api/v4/projects/${encoded_path}/merge_requests" \
    -H "PRIVATE-TOKEN: ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg src "$branch" --arg tgt "main" --arg title "$title" --arg desc "$body" \
      '{ source_branch: $src, target_branch: $tgt, title: $title, description: $desc }')")

  mr_url=$(echo "$response" | jq -r '.web_url // empty')

  # Retry with 'master'
  if [[ -z "$mr_url" ]]; then
    response=$(curl -sS "https://gitlab.com/api/v4/projects/${encoded_path}/merge_requests" \
      -H "PRIVATE-TOKEN: ${token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg src "$branch" --arg tgt "master" --arg title "$title" --arg desc "$body" \
        '{ source_branch: $src, target_branch: $tgt, title: $title, description: $desc }')")

    mr_url=$(echo "$response" | jq -r '.web_url // empty')
  fi

  echo "$mr_url"
}
