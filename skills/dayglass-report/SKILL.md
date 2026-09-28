---
name: dayglass-report
description: Review and freeze a dayglass work report.
---

# dayglass-report

1. Run `dayglass report --month YYYY-MM --questions`.
2. Present questions in date order, one at a time, without adding candidates.
3. Record each answer immediately with `dayglass note --question`.
4. Ask once about meetings outside Zoom, Meet, or Teams and record explicit times. Do not ask about intervals already covered by an `audio` span.
5. Re-run the report and show the remaining unassigned seconds.
6. Run `dayglass evidence --day YYYY-MM-DD` for bounded, redacted request/outcome material.
7. Draft one to three lines per project; keep repository names and PR numbers unchanged. Cite on each line the minutes from that day's `time` table that the line is based on. Per-project minute totals must equal that day's `time` table total. Do not write outcomes that are not in `evidence`. If a request exists but no result is confirmed, say started or in progress, and do not claim completion. If the totals do not match, delete lines or fix the minutes. Never change the `time` table to make the draft match.
8. Let the user review and correct the draft, then save it with `dayglass note --day --summary`.
9. Run `dayglass report --freeze --format csv` and ask the user to inspect and submit it manually.

Never invent candidates, treat a gap as a meeting, or send raw logs. Only the user's explicit answer may add a project or category.

## Recent days

A session can cover just the trailing days and then stop:

- Run `dayglass report --days N --questions` to list unresolved ranges from the last N local days, including today. The SessionStart reminder uses N = 7.
- Ask only 1 to 3 of those questions, in date order, then stop.
- Record every answer with `dayglass note --question` (or `--skip`). Do not invent another place to store answers.
