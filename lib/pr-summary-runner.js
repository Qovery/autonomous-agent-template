#!/usr/bin/env node
// ────────────────────────────────────────────────────────────────────────────────
// PR Summary Runner
//
// Summarizes a git diff into a human-readable pull request description via
// @anthropic-ai/claude-agent-sdk — a single tool-less turn, independent of
// whichever coding agent (Claude/Codex/Gemini/Cursor/OpenCode) made the change.
// Grounding the summary in the diff (rather than the ticket or the coding
// agent's own account) keeps it accurate and provider-agnostic.
//
// Environment:
//   DIFF_FILE    — path to a file containing the diff to summarize (required)
//   OUTPUT_FILE  — path to write the generated summary to (default: /tmp/pr-summary.md)
//   ISSUE_TITLE  — short issue title, for context only (optional)
//
// Exit code is non-zero, and OUTPUT_FILE is left unwritten, on any failure —
// callers must treat that as "no summary produced" and fall back.
// ────────────────────────────────────────────────────────────────────────────────
const { query } = require("@anthropic-ai/claude-agent-sdk");
const fs = require("fs");

const diffFile = process.env.DIFF_FILE || "";
const outputFile = process.env.OUTPUT_FILE || "/tmp/pr-summary.md";
const issueTitle = process.env.ISSUE_TITLE || "";

const MAX_DIFF_CHARS = 60000;

function log(msg) {
  process.stdout.write(`[pr-summary] ${msg}\n`);
}

function buildPrompt(diff, truncated) {
  return `You are writing a pull request description for the diff below${issueTitle ? ` (task: "${issueTitle}")` : ""}.

Write a concise, human-readable PR description in Markdown:
- 1-3 sentences: what changed and why, based only on what the diff shows.
- "## Changes" — a bullet list of the concrete changes.
- "## Testing" — only include this section if the diff itself adds or modifies test files; describe what they cover. Omit the section otherwise. Do not claim you ran anything.

Do not speculate beyond what the diff shows. Do not include the literal diff or any preamble like "Here is the description" — output only the Markdown description.
${truncated ? "\nNote: the diff was truncated for length; base your summary on the portion shown." : ""}

Diff:
${diff}`;
}

async function main() {
  if (!diffFile || !fs.existsSync(diffFile)) {
    log(`Diff file not found: ${diffFile || "(unset)"}`);
    process.exit(1);
  }

  let diff = fs.readFileSync(diffFile, "utf8");
  if (!diff.trim()) {
    log("Diff is empty — nothing to summarize");
    process.exit(1);
  }

  let truncated = false;
  if (diff.length > MAX_DIFF_CHARS) {
    diff = diff.slice(0, MAX_DIFF_CHARS);
    truncated = true;
  }

  const prompt = buildPrompt(diff, truncated);

  let text = "";
  for await (const event of query({
    prompt,
    options: { allowedTools: [] },
  })) {
    if (event.type === "result" && event.subtype === "success" && event.result) {
      text = event.result;
    }
  }

  if (!text.trim()) {
    log("No summary text produced");
    process.exit(1);
  }

  fs.writeFileSync(outputFile, text.trim() + "\n");
  log(`Wrote summary to ${outputFile}`);
}

main().catch((err) => {
  log(`Fatal error: ${err.message}`);
  process.exit(1);
});
