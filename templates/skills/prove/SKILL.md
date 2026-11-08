---
name: prove
description: Keep the PROOF9 requirements ledger (.evolve/REQUIREMENTS.md) honest by running the proof obligations of every REQ your changes touch and recording evidence. Use after implementing, before updating the spec.
---

# Proof Obligations

Read `.evolve/REQUIREMENTS.md` (if it is missing, create it with a `# Requirements Ledger` heading). An empty ledger
only means there are no existing REQs to check: still add REQs for new failures and fixed issues below.

## Which REQs apply

A REQ applies if any file you changed this session matches its **Scope**: globs such as
`src/auth/*`, or route patterns such as `POST /auth/login`.

## For each applicable REQ

- Skip it if its status is `waived` and the waiver has not expired.
- Run the checks for each gate in its **Obligations** (BUILD, UNIT, LINT, CONTRACT, E2E, SEC, PERF, DEMO, MANUAL).
- Save the last 200 lines of output to `.evolve/evidence/REQ-XXXX/<day>-<commit>-<gate>.txt`.
- All obligations pass: set the status to `satisfied` and add `Satisfied by: Day N, commit <short sha>`.
- A previously `satisfied` REQ now fails: set it to `regressed`. A regressed REQ blocks the commit, so fix it
  before moving on.

## New REQs

- Each new failure this session that has no REQ yet gets one at the bottom of the ledger, with
  `Source: Day N agent self-assessment`. Gates follow the failure: build error → `[BUILD]`, test failure →
  `[UNIT]`, API problem → `[UNIT, CONTRACT]`. Write test stubs if the evidence tests don't exist yet.
- Each GitHub issue you fixed (from `.evolve/ISSUES_TODAY.md`) gets a REQ with `Source: GitHub issue #N`,
  gates matching the issue, and its obligations run with evidence captured.

Use the next free id (highest `REQ-####` + 1) and the format shown in the comment at the top of the ledger.

## Commit

```
git add .evolve/REQUIREMENTS.md && git commit -m "Day N (HH:MM): update proof obligations"
```

Evidence files are gitignored on purpose; only the ledger is committed.
