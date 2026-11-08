---
name: evolve-status
description: Report how code-evolve is doing in this project (day, spec progress, schedule, open requirements, last session). Use when the user asks how evolution is going or what code-evolve has done.
metadata:
  managed-by: code-evolve
---

# code-evolve status

1. Run `npx code-evolve status`. When its output is not a terminal it prints JSON with `day`,
   `features` (total, done, partial, remaining), `mode`, `schedule`, `requirements` (open, regressed,
   satisfied, waived), `pendingSession` and `lastEntry`.
2. Summarize in a few sentences: the day count and spec progress, how cycles run (`mode` and
   `schedule`; no schedule means cycles are run by hand or from an agent session), and what the
   last journal entry says.
3. Call out anything that needs attention:
   - `requirements.regressed` above 0: something that used to work is broken, and the next cycle
     must fix it before new work.
   - `pendingSession` true: an in-session cycle was prepared and not finalized, so scheduled cycles
     are skipping. Offer to finish it with the `evolve-run` skill.
   - No features in the spec: offer the `evolve-setup` skill to draft one.
4. For more history, read the newest entries at the top of `.evolve/JOURNAL.md`.
