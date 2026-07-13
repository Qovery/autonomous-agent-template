# Qovery Autonomous Agent Template

A Docker image template for running autonomous AI coding agents on [Qovery RDE](https://www.qovery.com). When deployed as a Qovery environment, the container automatically picks up an issue from your tracker (**Linear** or **Jira**), runs an AI agent (Claude Code or OpenCode) to fix it, opens a pull request, and exits.

The image ships both integrations. At startup, `entrypoint.sh` auto-detects the
provider from the injected env vars (`JIRA_*` → Jira, else `LINEAR_*` → Linear)
and runs the matching `agent-run.sh`. Provider-agnostic machinery (git/PR, agent
runners, callback) is shared in `lib/`; each provider's folder (`linear/`,
`jira/`) holds only its `agent-run.sh` + API helper.

## How it works

1. The [RDE Portal](https://github.com/qovery/experiment/rde-portal) polls your tracker (Linear or Jira) for issues labeled `qovery-agent-ready`
2. For each issue, it launches an ephemeral Qovery environment using this template
3. The container's entrypoint:
   - Starts the agent governance proxy (if configured)
   - Detects the ticket provider and fetches the issue description
   - Clones the target repo and creates a branch
   - Runs the AI agent headless (`claude -p` or `opencode run`)
   - Commits, pushes, and opens a PR
   - Comments the PR link on the issue
   - Calls back the portal to record the result and stop the environment

## Quick start

### 1. Use this template directly

```dockerfile
FROM ghcr.io/qovery/autonomous-agent-template:latest

# Add your project-specific dependencies
RUN apt-get update && apt-get install -y your-deps
```

### 2. Or build from source

```bash
git clone https://github.com/Qovery/autonomous-agent-template.git
cd autonomous-agent-template
docker build -t my-autonomous-agent .
```

### 3. Configure in the RDE Portal

1. Create a blueprint using this image
2. Go to the blueprint's **Autonomous** tab
3. Select your Linear team, label, and workflow states
4. Enable the autonomous agent
5. Label a Linear issue with `qovery-agent-ready`

## Environment variables

These are injected automatically by the RDE Portal when it launches the environment. You don't need to set them manually.

### Common

| Variable | Description |
|----------|-------------|
| `RDE_AUTONOMOUS_AGENT` | `claude` or `opencode` |
| `RDE_RUN_CALLBACK_URL` | BFF callback URL for reporting results |
| `RDE_RUN_TIMEOUT_MIN` | Hard timeout for the agent (minutes) |
| `RDE_TICKET_PROVIDER` | Optional override: `linear` or `jira`. If unset, auto-detected from the provider vars below |
| `ANTHROPIC_API_KEY` | For Claude Code authentication |
| `REPO_COUNT` | Number of repositories to clone |
| `REPO_URL` / `REPO_1_URL` | Primary repo URL |
| `REPO_BRANCH` / `REPO_1_BRANCH` | Primary repo branch (default: `main`) |
| `REPO_TOKEN` / `REPO_1_TOKEN` | Git token for push + PR creation |
| `REPO_N_URL` | Additional repo URLs (N = 2, 3, ...) |
| `REPO_N_BRANCH` | Additional repo branches |
| `REPO_N_TOKEN` | Additional repo tokens |

### Linear (when using Linear)

| Variable | Description |
|----------|-------------|
| `LINEAR_API_TOKEN` | Linear API token (secret) |
| `LINEAR_ISSUE_ID` | Linear issue node ID to work on |
| `LINEAR_ISSUE_KEY` | Human-readable key (e.g., `ENG-123`) |

### Jira (when using Jira Cloud)

Auth is an OAuth 2.0 access token (Bearer). REST v3 (text fields are ADF,
flattened to plain text internally).

| Variable | Description |
|----------|-------------|
| `JIRA_BASE_URL` | Pre-computed API base (gateway + cloud id + version), e.g. `https://api.atlassian.com/ex/jira/<cloud_id>/rest/api/3/` |
| `JIRA_ACCESS_TOKEN` | OAuth 2.0 access token (secret), sent as `Authorization: Bearer` |
| `JIRA_ISSUE_KEY` | Issue key to work on (e.g., `PROJ-123`) — also the REST path id |

## Git providers

The repo is cloned/pushed and the PR is opened using a single `REPO_*_TOKEN`.
The auth header differs per provider (auto-detected from the repo URL):

| Provider | Clone/push | PR/MR API auth |
|----------|-----------|----------------|
| GitHub | `x-access-token:<token>` | `Authorization: Bearer` |
| GitLab | `oauth2:<token>` | `PRIVATE-TOKEN` |
| Bitbucket | `x-token-auth:<token>` | `Authorization: Bearer` (repo/workspace access token) |

## Controlling the agent from your tracker

Once the agent is running, you can control it by commenting on the issue (Linear or Jira):

| Command | Action |
|---------|--------|
| `/stop` | Stop the agent and its environment |
| `/restart` | Restart the environment |
| `/delete` | Stop and mark the run as done |
| `/status` | Show current agent status and environment state |

## RDE configuration

The `.config.rde.qovery.yml` file customizes which components are installed by `install.sh`. This template disables web IDE components (VS Code web) that aren't needed for headless autonomous mode, while keeping all AI agents and dev tooling.

## License

See [LICENSE](LICENSE) for details.
