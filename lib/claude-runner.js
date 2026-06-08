#!/usr/bin/env node
// ────────────────────────────────────────────────────────────────────────────────
// Claude Agent SDK Runner
//
// Runs Claude Code programmatically via @anthropic-ai/claude-agent-sdk.
// Streams real-time progress events to stdout (container logs) and to the
// BFF /progress endpoint (Linear agent session activities).
//
// Environment:
//   TASK_FILE     — path to the task markdown file (default: /tmp/task.md)
//   PROGRESS_URL  — BFF progress endpoint URL (optional)
//   WORK_DIR      — working directory for Claude (default: cwd)
// ────────────────────────────────────────────────────────────────────────────────
const { query } = require("@anthropic-ai/claude-agent-sdk");
const fs = require("fs");
const http = require("http");
const https = require("https");

const taskFile = process.env.TASK_FILE || "/tmp/task.md";
const progressUrl = process.env.PROGRESS_URL || "";
const workDir = process.env.WORK_DIR || process.cwd();

// ── Helpers ─────────────────────────────────────────────────────────────────

function log(msg) {
  process.stdout.write(`[claude-sdk] ${msg}\n`);
}

function postProgress(msg) {
  log(msg);
  if (!progressUrl) return;
  try {
    const body = JSON.stringify({ message: msg });
    const url = new URL(progressUrl);
    const transport = url.protocol === "https:" ? https : http;
    const req = transport.request(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
      timeout: 5000,
    });
    req.on("error", () => {}); // fire-and-forget
    req.end(body);
  } catch {
    // Best-effort: don't crash on progress post failure
  }
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  if (!fs.existsSync(taskFile)) {
    log(`Task file not found: ${taskFile}`);
    process.exit(1);
  }

  const prompt = fs.readFileSync(taskFile, "utf8").trim();
  if (!prompt) {
    log("Task file is empty");
    process.exit(1);
  }

  log(`Working directory: ${workDir}`);
  log(`Task: ${prompt.slice(0, 100)}${prompt.length > 100 ? "..." : ""}`);
  postProgress("Claude Agent SDK initialized. Starting work...");

  process.chdir(workDir);

  for await (const event of query({
    prompt,
    options: {
      allowedTools: [
        "Read", "Write", "Edit", "Bash", "Glob", "Grep",
        "WebFetch", "WebSearch",
      ],
    },
  })) {
    // ── Extract and forward meaningful progress events ──────────────
    try {
      if (event.type === "assistant" && event.message?.content) {
        for (const block of event.message.content) {
          if (block.type === "tool_use") {
            // Tool invocation: "Using Edit", "Using Bash", etc.
            const params = formatToolParams(block);
            postProgress(`Using ${block.name}${params}`);
          } else if (block.type === "text" && block.text && block.text.length > 10) {
            // Assistant thinking/response text (truncated)
            postProgress(block.text.slice(0, 200));
          }
        }
      } else if (event.type === "system" && event.subtype === "init") {
        log(`Session ID: ${event.session_id || event.data?.session_id || "unknown"}`);
      } else if (event.type === "result") {
        postProgress(`Completed (${event.subtype || "done"})`);
      }
    } catch {
      // Don't let event parsing errors crash the runner
    }
  }

  log("Claude finished successfully");
}

// Format tool parameters for progress messages
function formatToolParams(block) {
  if (!block.input) return "";
  if (block.name === "Edit" || block.name === "Write" || block.name === "Read") {
    return block.input.file_path ? `: ${block.input.file_path}` : "";
  }
  if (block.name === "Bash") {
    const cmd = block.input.command || "";
    return cmd ? `: ${cmd.slice(0, 80)}` : "";
  }
  if (block.name === "Glob") {
    return block.input.pattern ? `: ${block.input.pattern}` : "";
  }
  if (block.name === "Grep") {
    return block.input.pattern ? `: ${block.input.pattern}` : "";
  }
  return "";
}

main().catch((err) => {
  log(`Fatal error: ${err.message}`);
  if (err.stack) process.stderr.write(err.stack + "\n");
  process.exit(1);
});
