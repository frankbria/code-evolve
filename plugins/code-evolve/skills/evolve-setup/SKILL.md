---
name: evolve-setup
description: Install code-evolve in the current project and get it ready to evolve the codebase on its own. Use when the user wants to set up, install or onboard code-evolve, or when .evolve/ is missing.
metadata:
  managed-by: code-evolve
---

# Set up code-evolve

1. Confirm the project is a git repository. If it is not, offer to run `git init`.
2. Install the engine (safe to re-run; it never prompts and keeps existing state):

   ```bash
   npx -y code-evolve init --yes --agent <claude|codex|opencode>
   ```

   Pass the agent you are.
3. Help the user fill in `.evolve/vision.md` (what the project is for) and `.evolve/spec.md`
   (features, stack, priorities). For an existing codebase, draft both from what is already there
   and ask the user to confirm.
4. Explain the ways to run cycles: headless now (`npx code-evolve run`), on a schedule
   (`npx code-evolve start --every <hours>`), or inside this session with the `evolve-run` skill.
