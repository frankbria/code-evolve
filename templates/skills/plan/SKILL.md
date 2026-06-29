---
name: plan
description: Plan project structure and implementation strategy from .evolve/vision.md and .evolve/spec.md
tools: [bash, read_file, write_file, list_files]
---

# Planning

You are planning a project based on .evolve/vision.md and .evolve/spec.md. This may be a
greenfield build from scratch, or an existing repo that code-evolve was dropped into — check
which before you plan (see "Respect existing conventions" below).

## When to use this skill

- Day 0 (bootstrap) — plan the entire project structure
- Before implementing a complex feature — plan the approach
- When multiple spec features interact — plan the integration

## Respect existing conventions (check this first)

Before planning, decide whether this is greenfield or an existing repo:

- **Existing repo** = there's already source code and git history beyond the `.evolve/` scaffold.
- **Blank spec** = `.evolve/spec.md` still contains its unfilled placeholder comment — the `<!-- ... -->` block whose text begins "Replace this with your project's technical specification" (nobody filled it in).

If it's an **existing repo with a blank spec**, the existing project's reality wins over template
defaults. Before you plan anything, discover and adopt what's already there:

- Read `CONTRIBUTING.md`, `README.md`, and any `docs/` for stated conventions.
- Read the lint/format config (`.eslintrc*`, `ruff.toml`/`pyproject.toml`, `.prettierrc`, `rustfmt.toml`, etc.) and match the existing style.
- Mirror the existing test layout and framework — don't introduce a second one.
- Read the existing CI (`.github/workflows/`) to learn the real build/test/lint commands.
- Follow the existing directory layout, naming, and dependency choices.

Plan to extend the project *in its own idiom*. Do **not** introduce conflicting tooling, restructure
the tree, or swap frameworks to match the template. Treat the existing code as the spec until someone
fills `.evolve/spec.md` in.

## Process

1. **Read .evolve/vision.md** — understand the "why" and "what"
2. **Read .evolve/spec.md** — understand the "how": tech stack, architecture, features
3. **Identify constraints**:
   - What tech stack is specified?
   - What's the deployment target?
   - What testing strategy is required?
4. **Plan the structure**:
   - Directory layout
   - Key files and their responsibilities
   - Dependency graph between features
5. **Determine build order**:
   - What can be built first with no dependencies?
   - What depends on what?
   - What's the minimum viable feature set?

## Output

Write a clear implementation plan:

```
PROJECT PLAN — Day [N]

Structure:
  project/
  ├── [dir]/ — [purpose]
  └── [file] — [purpose]

Build Order:
1. [Feature] — [why first]
2. [Feature] — [depends on #1]
3. ...

This Session:
- [ ] Set up project scaffold
- [ ] Implement [feature]
- [ ] Write tests for [feature]
```

## Rules

- Follow .evolve/spec.md's tech stack exactly. Don't substitute technologies. **But** if the spec is still the blank template and the repo already has code, the existing stack is the truth — follow that instead (see "Respect existing conventions" above).
- Plan for testability from the start.
- Keep the structure as simple as possible — add complexity only when needed.
- Don't over-plan. Plan what you'll build THIS session, sketch the rest.
