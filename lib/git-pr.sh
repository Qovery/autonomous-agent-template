#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# Git clone/push + PR creation helpers for the autonomous agent
#
# Mirrors the token-authed URL pattern from rde-portal's git-push.ts:
#   github:    x-access-token:<token>
#   gitlab:    oauth2:<token>
#   bitbucket: x-token-auth:<token>
# ────────────────────────────────────────────────────────────────────────────────

# Detect git provider from a repo URL. Matches the product name anywhere in the
# URL so self-hosted hosts (github.example.com, gitlab.corp, bitbucket.acme.io)
# resolve too. Fully custom domains (git.acme.com) can't be told apart and fall
# to the github default — pass the provider explicitly if that's your setup.
# Usage: detect_git_provider <repo_url>
# Outputs: github | gitlab | bitbucket
detect_git_provider() {
  local url="$1"
  case "$url" in
    *github*)    echo "github" ;;
    *gitlab*)    echo "gitlab" ;;
    *bitbucket*) echo "bitbucket" ;;
    *)           echo "github" ;;  # default for unrecognised self-hosted hosts
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
    # x-token-auth is the required Basic-auth username for both Bitbucket Cloud
    # and Data Center project/repository access tokens.
    bitbucket) echo "${proto}x-token-auth:${token}@${host_and_path}" ;;
    *)         echo "${proto}${token}@${host_and_path}" ;;
  esac
}

# Extract owner/repo from a git URL — the last two path segments.
# github: owner/repo · bitbucket cloud: workspace/repo_slug ·
# bitbucket server (.../scm/KEY/repo.git): projectKey/repoSlug.
# Usage: extract_owner_repo <repo_url>
extract_owner_repo() {
  local repo_url="$1"
  echo "$repo_url" | sed 's|\.git$||' | sed 's|/$||' | grep -oE '[^/]+/[^/]+$'
}

# Extract host[:port] from a repo URL (no scheme, no userinfo, no path).
# Usage: _repo_host <repo_url>
_repo_host() {
  echo "$1" | sed -E 's#^[a-z][a-z0-9+.-]*://##; s#^[^@/]*@##; s#/.*$##'
}

# GitHub REST API base for a host. github.com uses api.github.com; GitHub
# Enterprise Server exposes the API under /api/v3 on its own host.
# Usage: _github_api_base <host>
_github_api_base() {
  if [[ "$1" == "github.com" ]]; then echo "https://api.github.com"; else echo "https://$1/api/v3"; fi
}

# GitLab project path = the full namespace after the host (supports subgroups),
# minus a trailing .git. Usage: _gitlab_project_path <repo_url>
_gitlab_project_path() {
  echo "$1" | sed -E 's#^[a-z][a-z0-9+.-]*://##; s#^[^@/]*@##; s#^[^/]+/##; s#\.git$##; s#/$##'
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

  case "$provider" in
    github)
      _create_github_pr "$repo_url" "$token" "$branch" "$title" "$body"
      ;;
    gitlab)
      _create_gitlab_mr "$repo_url" "$token" "$branch" "$title" "$body"
      ;;
    bitbucket)
      _create_bitbucket_pr "$repo_url" "$token" "$branch" "$title" "$body"
      ;;
    *)
      # Unknown provider: push only, no PR API
      echo ""
      ;;
  esac
}

# ── GitHub PR (github.com + Enterprise Server) ───────────────────────────────

_create_github_pr() {
  local repo_url="$1" token="$2" branch="$3" title="$4" body="$5"
  local host owner_repo api response pr_url base
  host=$(_repo_host "$repo_url")
  owner_repo=$(extract_owner_repo "$repo_url")
  api="$(_github_api_base "$host")/repos/${owner_repo}/pulls"

  # Try 'main' then 'master' as the base branch.
  for base in main master; do
    response=$(curl -sS "$api" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$(jq -n --arg title "$title" --arg body "$body" --arg head "$branch" --arg base "$base" \
        '{ title: $title, body: $body, head: $head, base: $base }')")

    pr_url=$(echo "$response" | jq -r '.html_url // empty')
    [[ -n "$pr_url" ]] && break
  done

  echo "$pr_url"
}

# ── GitLab MR (gitlab.com + self-hosted) ─────────────────────────────────────

_create_gitlab_mr() {
  local repo_url="$1" token="$2" branch="$3" title="$4" body="$5"
  local host encoded_path api response mr_url base
  host=$(_repo_host "$repo_url")
  encoded_path=$(_gitlab_project_path "$repo_url" | jq -Rr @uri)
  api="https://${host}/api/v4/projects/${encoded_path}/merge_requests"

  # Try 'main' then 'master' as the target branch.
  for base in main master; do
    response=$(curl -sS "$api" \
      -H "PRIVATE-TOKEN: ${token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg src "$branch" --arg tgt "$base" --arg title "$title" --arg desc "$body" \
        '{ source_branch: $src, target_branch: $tgt, title: $title, description: $desc }')")

    mr_url=$(echo "$response" | jq -r '.web_url // empty')
    [[ -n "$mr_url" ]] && break
  done

  echo "$mr_url"
}

# ── Bitbucket PR ─────────────────────────────────────────────────────────────
# Dispatches by host: Cloud (bitbucket.org) uses the 2.0 API; Data Center /
# Server uses the /rest/api/1.0 API — a different endpoint, body, and response.
# Both authenticate with the access token via Bearer.

_create_bitbucket_pr() {
  local repo_url="$1" token="$2" branch="$3" title="$4" body="$5"
  local host
  host=$(_repo_host "$repo_url")

  if [[ "$host" == "bitbucket.org" ]]; then
    _create_bitbucket_cloud_pr "$repo_url" "$token" "$branch" "$title" "$body"
  else
    _create_bitbucket_server_pr "$repo_url" "$host" "$token" "$branch" "$title" "$body"
  fi
}

# Bitbucket Cloud — owner_repo is "<workspace>/<repo_slug>".
_create_bitbucket_cloud_pr() {
  local repo_url="$1" token="$2" branch="$3" title="$4" body="$5"
  local owner_repo api response pr_url base
  owner_repo=$(extract_owner_repo "$repo_url")
  api="https://api.bitbucket.org/2.0/repositories/${owner_repo}/pullrequests"

  for base in main master; do
    response=$(curl -sS "$api" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg title "$title" --arg desc "$body" --arg src "$branch" --arg tgt "$base" \
        '{ title: $title, description: $desc, source: { branch: { name: $src } }, destination: { branch: { name: $tgt } } }')")

    pr_url=$(echo "$response" | jq -r '.links.html.href // empty')
    [[ -n "$pr_url" ]] && break
  done

  echo "$pr_url"
}

# Bitbucket Data Center / Server — repo URL is .../scm/<projectKey>/<repoSlug>.git.
# Refs are fully-qualified (refs/heads/…); same-repo PRs omit the repository object.
_create_bitbucket_server_pr() {
  local repo_url="$1" host="$2" token="$3" branch="$4" title="$5" body="$6"
  local owner_repo proj repo api response pr_url base
  owner_repo=$(extract_owner_repo "$repo_url")
  proj="${owner_repo%%/*}"; repo="${owner_repo##*/}"
  api="https://${host}/rest/api/1.0/projects/${proj}/repos/${repo}/pull-requests"

  for base in main master; do
    response=$(curl -sS "$api" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg title "$title" --arg desc "$body" --arg src "refs/heads/$branch" --arg tgt "refs/heads/$base" \
        '{ title: $title, description: $desc, fromRef: { id: $src }, toRef: { id: $tgt } }')")

    pr_url=$(echo "$response" | jq -r '.links.self[0].href // empty')
    [[ -n "$pr_url" ]] && break
  done

  echo "$pr_url"
}
