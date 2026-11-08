---
name: evolve-run
description: Run one code-evolve evolution cycle inside this agent session (prepare, do the work, verify, finalize). Use only when the user explicitly asks to run or continue an evolution cycle here.
---

# Run an evolution cycle in this session

Requires code-evolve to be installed (`.evolve/` exists; otherwise use the `evolve-setup` skill).

1. `bash .evolve/scripts/evolve.sh prepare`. If it reports a pending session, ask the user whether to
   finish it (skip to step 3) or abandon it (`rm -rf .evolve/run`).
2. Read `.evolve/run/PROMPT.md` and do exactly what it says.
3. `bash .evolve/scripts/evolve.sh verify`. On failure, read `.evolve/run/ERRORS.md`, fix the code, and run
   verify again. After three failed attempts, stop fixing.
4. `bash .evolve/scripts/evolve.sh finalize --no-agent`. This commits, tags and pushes the session, or
   reverts it if verification still fails.
