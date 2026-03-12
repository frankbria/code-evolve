# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What This Is

A self-evolving project builder. Given a `vision.md` (the "why") and a `spec.md`
(the "how"), it autonomously builds the project from scratch and continues
improving it session after session.

The evolution loop runs every 4 hours via GitHub Actions (`scripts/evolve.sh`),
which invokes Claude Code CLI in non-interactive mode to read the vision/spec,
assess current state, implement features, verify the build, and commit.

## How It Works

1. `scripts/evolve.sh` orchestrates each evolution session
2. It reads `vision.md`, `spec.md`, current project state, and GitHub issues
3. Claude Code implements the next highest-priority work
4. Build verification runs (auto-detected from project stack)
5. Journal entry is written, issue responses posted
6. Changes are committed, tagged, and pushed

## Project Structure

```
code-evolve/
├── vision.md              # Project vision (the "why" and "what")
├── spec.md                # Technical spec (the "how", with feature checklist)
├── IDENTITY.md            # Agent constitution (DO NOT MODIFY)
├── JOURNAL.md             # Evolution log (append at top, never delete)
├── LEARNINGS.md           # Cached knowledge from research
├── DAY_COUNT              # Current evolution day
├── scripts/
│   ├── evolve.sh          # Master orchestrator (DO NOT MODIFY)
│   ├── format_issues.py   # Issue sanitization (DO NOT MODIFY)
│   └── detect_stack.sh    # Stack detection for build verification
├── skills/                # Agent behavior definitions
│   ├── evolve/            # Self-modification rules
│   ├── self-assess/       # Gap analysis
│   ├── communicate/       # Journal and issue responses
│   ├── research/          # Web research
│   └── plan/              # Planning from vision/spec
├── .github/workflows/
│   ├── evolve.yml         # Cron trigger (every 4h)
│   └── ci.yml             # Build verification on push/PR
└── src/                   # THE PROJECT (built by the agent)
```

## Running Locally

```bash
# Run a full evolution cycle
ANTHROPIC_API_KEY=sk-... ./scripts/evolve.sh

# Run with a specific model
ANTHROPIC_API_KEY=sk-... MODEL=claude-opus-4-6 ./scripts/evolve.sh

# Force run (bypass schedule gate)
ANTHROPIC_API_KEY=sk-... FORCE_RUN=true ./scripts/evolve.sh
```

## Safety Rules

These files are protected and must never be modified by the agent:
- `IDENTITY.md` — agent constitution
- `scripts/evolve.sh` — orchestrator
- `scripts/format_issues.py` — input sanitization
- `.github/workflows/` — CI/CD safety net

## Getting Started

1. Edit `vision.md` with your project vision
2. Edit `spec.md` with technical specification and feature checklist
3. Set `ANTHROPIC_API_KEY` in GitHub repository secrets
4. Push to GitHub — the evolution workflow will start building automatically
5. Or run locally: `ANTHROPIC_API_KEY=sk-... ./scripts/evolve.sh`

## State Files

| File | Purpose | Mutability |
|------|---------|-----------|
| vision.md | North star | Human-edited |
| spec.md | Blueprint with checklist | Human + agent (checkboxes) |
| JOURNAL.md | Session log | Append-only (top) |
| LEARNINGS.md | Cached knowledge | Append (new sections) |
| DAY_COUNT | Evolution day | Written each run |
| ISSUES_TODAY.md | Fetched issues | Generated (gitignored) |
| ISSUE_RESPONSE.md | Issue responses | Generated (gitignored) |
