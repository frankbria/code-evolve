# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What This Is

An npm CLI package (`code-evolve`) that turns any project into a self-evolving
codebase. Users run `npx code-evolve init` in their project, fill in `.evolve/vision.md`
and `.evolve/spec.md`, and the framework autonomously builds and improves the project
session after session using Claude Code CLI.

## Repository Structure

```
code-evolve/                  # npm package source
├── package.json              # npm package config (bin: code-evolve)
├── tsconfig.json             # TypeScript config
├── src/                      # CLI source (TypeScript)
│   ├── cli.ts                # Entrypoint (commander)
│   ├── commands/
│   │   ├── init.ts           # code-evolve init
│   │   ├── run.ts            # code-evolve run
│   │   ├── status.ts         # code-evolve status
│   │   └── eject.ts          # code-evolve eject
│   └── utils/
│       ├── paths.ts          # Path resolution
│       ├── checks.ts         # Dependency checking
│       └── output.ts         # TTY/JSON output
├── templates/                # Files installed by `init`
│   ├── scripts/              # evolve.sh, detect_stack.sh, format_issues.py
│   ├── skills/               # Agent behavior definitions (5 SKILL.md files)
│   ├── state/                # IDENTITY.md, JOURNAL.md, LEARNINGS.md, DAY_COUNT, vision.md, spec.md
│   └── workflows/            # GitHub Actions (evolve.yml, ci.yml)
├── dist/                     # Compiled output (gitignored)
└── .github/workflows/        # CI for this package
```

## Development

```bash
npm install           # Install dependencies
npm run build         # Compile TypeScript to dist/
npm run dev           # Watch mode
npm run lint          # Type-check without emitting
```

## How It Works (User Perspective)

1. User runs `code-evolve init` in their project
2. Creates `.evolve/` with scripts, skills, state files
3. Creates `vision.md` and `spec.md` templates in `.evolve/`
4. User fills in vision and spec
5. `code-evolve run` executes one evolution cycle via `.evolve/scripts/evolve.sh`
6. `evolve.sh` invokes Claude Code CLI to read vision/spec, build features, verify, commit
7. Optionally: `--with-ci` installs GitHub Actions for auto-evolution every 4 hours

## Key Design Decisions

- **`.evolve/` namespace**: All framework files live in `.evolve/` to avoid polluting the project root
- **`PROJECT_DIR=.`**: The project being built IS the repo root (not a subdirectory)
- **`EVOLVE_DIR` env var**: All paths in `evolve.sh` are relative to this variable
- **Templates shipped with npm package**: `init` copies from `node_modules/code-evolve/templates/`
- **vision.md and spec.md in .evolve/**: User documents live alongside other state files to avoid filename collisions

## Protected Files (in templates)

These must not be modified by the evolution agent:
- `.evolve/IDENTITY.md` — agent constitution
- `.evolve/scripts/evolve.sh` — orchestrator
- `.evolve/scripts/format_issues.py` — input sanitization
- `.github/workflows/evolve/` — CI/CD safety net
