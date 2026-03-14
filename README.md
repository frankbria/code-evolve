# code-evolve

A self-evolving project builder. Give it a vision and a spec, and it autonomously builds your project from scratch — then keeps improving it, session after session.

Powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Inspired by [yologdev/yoyo-evolve](https://github.com/yologdev/yoyo-evolve), which pioneered the concept of autonomous, journal-driven evolution loops for AI agents. code-evolve adapts that architecture into an installable CLI tool that drops into any existing project.

## How It Works

You write two documents:

- **vision.md** — the "why" and "what" (1-2 pages)
- **spec.md** — the "how" (tech stack, architecture, prioritized feature checklist)

The evolution engine reads these, assesses the current project state, implements the next highest-priority work, verifies the build, writes a journal entry, and commits. Every cycle closes the gap between spec and reality.

## Install

```bash
npm install -g code-evolve
```

Or use directly with npx — no global install needed.

## Quick Start

```bash
cd my-project
npx code-evolve init        # scaffold .evolve/, vision.md, spec.md

# Edit vision.md and spec.md with your project details

export ANTHROPIC_API_KEY=sk-...
npx code-evolve start       # start the evolution engine
```

That's it. The engine runs every 4 hours by default, building your project incrementally.

## Commands

| Command | Description |
|---------|-------------|
| `code-evolve init` | Initialize `.evolve/` in the current project |
| `code-evolve start` | Start the evolution engine (local cron job) |
| `code-evolve stop` | Stop the evolution engine |
| `code-evolve run` | Run a single evolution cycle manually |
| `code-evolve status` | Show current day, feature progress, schedule |
| `code-evolve eject` | Remove the framework, keep your project files |

### `init` Options

```
--with-ci    Install GitHub Actions workflows for cloud evolution
--force      Overwrite existing .evolve/ (preserves journal/learnings)
```

### `start` Options

```
--every <hours>   Run every N hours (default: 4)
--model <model>   LLM model (default: claude-sonnet-4-6)
--run-now         Also run the first cycle immediately
```

### `run` Options

```
--model <model>      LLM model (default: claude-sonnet-4-6)
--timeout <seconds>  Max session time (default: 3600)
--force              Bypass schedule gate
```

## What Gets Created

After `code-evolve init`, your project looks like this:

```
my-project/
├── vision.md              # Your project vision (edit this)
├── spec.md                # Your technical spec (edit this)
├── .evolve/
│   ├── scripts/           # Evolution orchestrator (protected)
│   ├── skills/            # Agent behavior definitions (protected)
│   ├── IDENTITY.md        # Agent constitution (protected)
│   ├── JOURNAL.md         # Session log (append-only)
│   ├── LEARNINGS.md       # Cached research
│   └── DAY_COUNT          # Evolution day counter
└── .github/workflows/     # (if --with-ci)
    └── evolve/            # Namespaced — won't touch your existing CI
```

## The Evolution Loop

Each cycle follows this sequence:

1. **Assess** — Read vision, spec, journal. Compare spec features vs. current implementation.
2. **Prioritize** — Fix CI failures > bootstrap > next spec feature > bugs > community issues.
3. **Implement** — Write code and tests, verify the build passes.
4. **Journal** — Write an honest entry about what worked, what didn't, what's next.
5. **Commit** — Tag the session and push.

The agent also responds to GitHub issues labeled `agent-input`, `agent-self`, or `agent-help-wanted`.

## Stack Detection

The engine auto-detects your project's build system and runs the appropriate verification commands:

| Stack | Detection | Build | Test |
|-------|-----------|-------|------|
| TypeScript | `tsconfig.json` | `npm run build` | `npm run test` |
| Next.js | `"next"` in package.json | `npm run build` | `npm run test` |
| Python | `pyproject.toml` | `uv sync` | `uv run pytest` |
| Rust | `Cargo.toml` | `cargo build` | `cargo test` |
| Go | `go.mod` | `go build ./...` | `go test ./...` |

Package managers (npm, yarn, pnpm, bun) and Python tooling (uv, poetry, pip) are detected automatically.

## Local vs. Cloud

**Local** (`code-evolve start`):
- Sets up a cron job on your machine
- Stores API key securely in `.evolve/.env` (gitignored, mode 600)
- Logs to `.evolve/evolve.log`

**Cloud** (`code-evolve init --with-ci`):
- Installs GitHub Actions workflows in `.github/workflows/evolve/`
- Runs every 4 hours with retry logic (3 attempts)
- Set `ANTHROPIC_API_KEY` in your repository secrets

Both paths run the same `evolve.sh` orchestrator.

## Safety

Protected files that the agent cannot modify:
- `.evolve/IDENTITY.md` — the agent constitution
- `.evolve/scripts/` — the orchestrator and input sanitization
- `.github/workflows/evolve/` — the CI safety net

GitHub issue content is treated as untrusted input with boundary markers and HTML comment stripping to prevent prompt injection.

## Upgrading

```bash
npm update -g code-evolve
code-evolve init --force     # updates scripts and skills, preserves your journal/learnings
```

## Ejecting

```bash
code-evolve eject
```

Stops the engine, removes `.evolve/` and workflows. Your `vision.md`, `spec.md`, and everything the agent built are preserved.

## Requirements

- Node.js >= 18
- Python 3
- Git
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- `ANTHROPIC_API_KEY`

## Acknowledgments

This project builds on the architecture pioneered by [yoyo-evolve](https://github.com/yologdev/yoyo-evolve) by [yologdev](https://github.com/yologdev). The core concepts — autonomous evolution loops, journal-driven memory, spec-driven feature prioritization, and build verification with automatic rollback — originate from that project. code-evolve adapts these ideas into a portable, installable CLI tool.

## License

MIT
