---
name: dayglass-search
description: Search local dayglass work logs, AI usage, and GitHub output from natural-language questions without exposing raw logs or window titles.
---

# dayglass-search

Translate the user's question into the smallest relevant local dayglass query.

1. Resolve relative dates in the user's local timezone and state the searched date range. If no period is given, use the current month.
2. Run `dayglass report --month YYYY-MM --format json --no-titles` once for each calendar month in the range.
3. Use `time` for work duration, `ai` for sessions, turns, edits, and tokens, `output` for commits and pull requests, and `blocks` for time-of-day searches. Filter all results to the requested dates and projects.
4. When the user asks what happened in an AI conversation, run `dayglass evidence --day YYYY-MM-DD` only for the relevant day. Treat it as a bounded, redacted excerpt, not a complete transcript.
5. Answer with the matched period, totals, and whether each value is confirmed, inferred, or unassigned. Keep unknowns unknown and distinguish observed activity from human-confirmed work.

Never read files under `~/Library/Application Support/dayglass/otlp/` or raw Claude Code/Codex transcripts directly. Never expose window titles, question evidence, raw prompts or responses, tool arguments, or tool results. Do not run `note`, `freeze`, `reap`, `setup`, or other explicit mutation commands; the normal GitHub synchronization attempted by `report` is allowed. If the safe report and redacted evidence cannot answer the question, say what is unavailable instead of guessing.
