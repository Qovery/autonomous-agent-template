#!/usr/bin/env node
// ────────────────────────────────────────────────────────────────────────────────
// Codex SDK Runner
//
// Runs OpenAI Codex programmatically via @openai/codex-sdk.
// Streams real-time progress events to stdout (container logs) and to the
// BFF /progress endpoint (Linear agent session activities).
//
// Environment:
//   TASK_FILE     — path to the task markdown file (default: /tmp/task.md)
//   PROGRESS_URL  — BFF progress endpoint URL (optional)
//   WORK_DIR      — working directory for Codex (default: cwd)
// ────────────────────────────────────────────────────────────────────────────────
const { Codex } = require("@openai/codex-sdk");
const fs = require("fs");
const http = require("http");
const https = require("https");

const taskFile = process.env.TASK_FILE || "/tmp/task.md";
const progressUrl = process.env.PROGRESS_URL || "";
const workDir = process.env.WORK_DIR || process.cwd();

// ── Helpers ─────────────────────────────────────────────────────────────────

function log(msg) {
  process.stdout.write(`[codex-sdk] ${msg}\n`);
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
    // Best-effort
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
  postProgress("Codex SDK initialized. Starting work...");

  const codex = new Codex();
  const thread = codex.startThread({
    workingDirectory: workDir,
    skipGitRepoCheck: true,
  });

  const { events } = await thread.runStreamed(prompt);

  for await (const event of events) {
    try {
      switch (event.type) {
        case "item.completed": {
          const item = event.item;
          if (item.type === "tool_call") {
            postProgress(`Using ${item.name || "tool"}${item.arguments ? ": " + String(item.arguments).slice(0, 100) : ""}`);
          } else if (item.type === "message" && item.content) {
            const text = typeof item.content === "string"
              ? item.content
              : Array.isArray(item.content)
                ? item.content.map((c) => c.text || "").join("").slice(0, 200)
                : "";
            if (text.length > 10) postProgress(text.slice(0, 200));
          }
          break;
        }
        case "turn.completed":
          postProgress("Turn completed");
          break;
        case "error":
          log(`Error: ${event.message || JSON.stringify(event)}`);
          break;
      }
    } catch {
      // Don't let event parsing errors crash the runner
    }
  }

  log("Codex finished successfully");
}

main().catch((err) => {
  log(`Fatal error: ${err.message}`);
  if (err.stack) process.stderr.write(err.stack + "\n");
  process.exit(1);
});
