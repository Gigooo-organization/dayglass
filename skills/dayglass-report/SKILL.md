---
name: dayglass-report
description: Review and freeze a dayglass work report.
---

# dayglass-report

1. Run `dayglass report --month YYYY-MM --questions`.
2. Present questions in date order, one at a time, without adding candidates.
3. Record each answer immediately with `dayglass note --question`.
4. Ask once about meetings outside Zoom, Meet, or Teams and record explicit times.
5. Re-run the report and show the remaining unassigned seconds.
6. Run `dayglass evidence --day YYYY-MM-DD` for bounded, redacted request/outcome material.
7. Draft one to three lines per project; keep repository names and PR numbers unchanged.
8. Let the user review and correct the draft, then save it with `dayglass note --day --summary`.
9. Run `dayglass report --freeze --format csv` and ask the user to inspect and submit it manually.

Never invent candidates, treat a gap as a meeting, or send raw logs. Only the user's explicit answer may add a project or category.
