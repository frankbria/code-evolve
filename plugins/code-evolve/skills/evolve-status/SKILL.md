---
name: evolve-status
description: Report how code-evolve is doing in this project (day, spec progress, schedule, open requirements, last session). Use when the user asks how evolution is going or what code-evolve has done.
metadata:
  managed-by: code-evolve
---

# code-evolve status

1. Run `npx code-evolve status`. When its output is not a terminal it prints JSON with `day`,
   `features` (total, done, partial, remaining), `mode`, `schedule`, `requirements` (open, regressed,
   satisfied, waived), `pendingSession`, `abandonedSession`, `engineVersion`, `engineDrift` and `lastEntry`.
   If `command -v code-evolve` finds an installed CLI, run `code-evolve` instead of `npx code-evolve`
   in every command of this skill. Otherwise, under Codex, run each `npx` command here with
   `npm_config_cache="${TMPDIR:-/tmp}/code-evolve-npm"` in front (the sandbox keeps `~/.npm`
   read-only), and add `--offline` after `npx` when `echo "$CODEX_SANDBOX_NETWORK_DISABLED"` prints
   `1` (without it, npx waits until the command times out). If status still cannot run, say so and
   report from the files it reads: `.evolve/config.json` (mode, `engineVersion`), the checkboxes in
   `.evolve/spec.md`, the `## REQ-` entries and their status in `.evolve/REQUIREMENTS.md`,
   `.evolve/run/` (a cycle prepared and not finalized), and `.evolve/JOURNAL.md`.
2. Summarize in a few sentences: the day count and spec progress, how cycles run (`schedule` is the
   local cron; `mode` `ci` or `both` means GitHub Actions also runs them; `mode` `native` means the
   user set up the agent's own scheduler, which code-evolve cannot see, so judge whether it is
   firing from the dates of the journal entries; with none of these, cycles are run by hand or
   from an agent session), how many
   requirements are open (work the agent owes), and what the last journal entry says.
3. Call out anything that needs attention:
   - `requirements.regressed` above 0: something that used to work is broken, and the next cycle
     must fix it before new work.
   - `pendingSession` true: an in-session cycle was prepared recently and not finalized, so
     scheduled cycles are skipping. Offer to finish it with the `evolve-run` skill.
   - `abandonedSession` true: an old unfinished session; the next cycle will discard it.
   - `engineDrift` not empty, or `engineVersion` older than `npx code-evolve --version`: the installed
     engine is out of date. Offer `npx code-evolve upgrade` (it needs a clean git tree and keeps the
     vision, spec, history and config).
     `null` means they could not be compared (an unreadable file); say so.
   - No features in the spec: offer the `evolve-setup` skill to draft one.
4. For more history, read the newest entries at the top of `.evolve/JOURNAL.md`.
