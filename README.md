# Qovery Autonomous Agent Template

A Docker image template for running autonomous AI coding agents on [Qovery RDE](https://www.qovery.com). When deployed as a Qovery environment, the container automatically picks up a Linear issue, runs an AI agent (Claude Code or OpenCode) to fix it, opens a pull request, and exits.

## How it works

1. The [RDE Portal](https://github.com/qovery/experiment/rde-portal) polls Linear for issues labeled `qovery-agent-ready`
2. For each issue, it launches an ephemeral Qovery environment using this template
3. The container's entrypoint:
   - Starts the agent governance proxy (if configured)
   - Fetches the Linear issue description
   - Clones the target repo and creates a branch
   - Runs the AI agent headless (`claude -p` or `opencode run`)
   - Commits, pushes, and opens a PR
   - Comments the PR link on the Linear issue
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

| Variable | Description |
|----------|-------------|
| `LINEAR_API_TOKEN` | Linear API token (secret) |
| `LINEAR_ISSUE_ID` | Linear issue node ID to work on |
| `LINEAR_ISSUE_KEY` | Human-readable key (e.g., `ENG-123`) |
| `RDE_AUTONOMOUS_AGENT` | `claude` or `opencode` |
| `RDE_RUN_CALLBACK_URL` | BFF callback URL for reporting results |
| `RDE_RUN_TIMEOUT_MIN` | Hard timeout for the agent (minutes) |
| `ANTHROPIC_API_KEY` | For Claude Code authentication |
| `BLUEPRINT_GIT_REPOSITORY` | Target repo URL |
| `BLUEPRINT_GIT_TOKEN` | Git token for push + PR creation |
| `BLUEPRINT_GIT_PROVIDER` | `github`, `gitlab`, or `bitbucket` |

## Controlling the agent from Linear

Once the agent is running, you can control it by commenting on the Linear issue:

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
