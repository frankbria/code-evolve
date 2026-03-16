# code-evolve

**Describe what you want. Walk away. Come back to working software.**

code-evolve is an autonomous project builder. Give it a vision and a technical spec, and it builds your project from scratch — then keeps improving it, session after session, commit after commit, day after day.

You define the *what* and *why*. The agent figures out the *how*.

[![npm version](https://img.shields.io/npm/v/code-evolve.svg)](https://www.npmjs.com/package/code-evolve)
[![license](https://img.shields.io/npm/l/code-evolve.svg)](https://github.com/frankbria/code-evolve/blob/main/LICENSE)

---

## The Idea

Most AI coding tools wait for you to tell them what to do next. code-evolve doesn't wait. It reads your vision, checks the spec, looks at what's already built, decides what to work on, implements it, verifies the build passes, writes a journal entry about what it learned, and commits. Then it does it again. And again.

Every 4 hours, your project gets a little closer to matching your vision.

```
Day 0  — Reads your spec. Sets up the project scaffold. First test passes.
Day 1  — Implements the core feature. Writes integration tests.
Day 3  — Adds the CLI interface. Fixes a bug from Day 1.
Day 7  — Responds to a GitHub issue. Polishes error messages.
Day 14 — Your project works. You barely touched a keyboard.
```

---

## Getting Started: New Project

Starting from scratch? Three steps:

### 1. Initialize

```bash
npx code-evolve init
```

This creates `.evolve/` with templates for your vision and spec.

### 2. Define your vision and spec

You have three options — pick the one that fits:

**Option A: Guided interview** (recommended for first-timers)

```bash
code-evolve vision
```

Five rounds of Socratic questions draw out your project vision — what you're building, who it's for, what problem it solves, and what success looks like. Your answers are assembled into `.evolve/vision.md` with your approval.

Then write `.evolve/spec.md` by hand — define your tech stack, architecture, and a prioritized feature checklist.

**Option B: Write both files directly**

Edit `.evolve/vision.md` and `.evolve/spec.md` using the templates as a guide. The templates include examples and comments explaining what each section needs.

### 3. Start building

```bash
export ANTHROPIC_API_KEY=sk-...    # or the key for your chosen agent
code-evolve start
```

The engine runs on a schedule (every 4 hours by default) and starts building your project autonomously.

> **Tip:** After installing globally (`npm install -g code-evolve`), you can use `ce` as a shorthand — `ce init`, `ce start`, `ce status`, etc.

---

## Getting Started: Existing Project

Already have a codebase and docs? code-evolve can adopt your project.

### 1. Initialize

```bash
cd your-project
npx code-evolve init
```

### 2. Import your existing documents

If you already have a PRD, technical spec, or README with features listed:

```bash
# Convert an existing spec document into code-evolve format
code-evolve migrate spec ./docs/technical-spec.md

# AI-powered conversion (deeper analysis, cross-references your codebase)
code-evolve migrate spec ./PRD.md --ai

# Convert an existing overview into vision format
code-evolve migrate vision ./docs/overview.md
```

The `migrate` command extracts features, tech stack, and architecture from your existing docs and formats them for code-evolve. Use `--ai` for smarter conversion that checks which features are already implemented.

You can also run the guided interview to refine an existing vision:

```bash
code-evolve vision --refine
```

This loads your current `.evolve/vision.md` and walks you through each section, showing your previous answers so you can update or keep them.

### 3. Review and start

Check the generated files in `.evolve/`, make any adjustments, then:

```bash
export ANTHROPIC_API_KEY=sk-...
code-evolve start
```

The agent picks up where your project left off — it reads the codebase, checks which spec features are already implemented, and starts working on what's missing.

---

## How the Evolution Loop Works

Each cycle is autonomous and self-correcting:

```
  Read vision + spec + journal
         |
         v
  Assess current state ---- "What exists vs. what's specified?"
         |
         v
  Prioritize work ---------- CI fix > bootstrap > next feature > bugs > issues
         |
         v
  Implement + test ---------- Write code, run build, verify
         |                         |
         |                    Build fails?
         |                         |
         |                    Fix it (up to 3 tries)
         |                         |
         |                    Still fails? Revert. Journal the failure.
         |
         v
  Journal entry ------------ Honest log: what worked, what didn't, what's next
         |
         v
  Commit + tag ------------- "Day 5 (09:00): add JWT auth with refresh tokens"
```

The journal is the agent's memory across sessions. It reads its own history to avoid repeating mistakes and to build on what worked.

## Commands

All commands are available as both `code-evolve <cmd>` and `ce <cmd>`.

| Command | What it does |
|---------|-------------|
| `code-evolve init` | Scaffold `.evolve/` with vision and spec templates |
| `code-evolve vision` | Guided Socratic interview to generate `.evolve/vision.md` |
| `code-evolve migrate` | Convert an existing spec/vision document into code-evolve format |
| `code-evolve start` | Turn on the evolution engine (local cron) |
| `code-evolve stop` | Pause evolution |
| `code-evolve run` | Run one cycle manually |
| `code-evolve status` | Check progress — day count, features done, schedule |
| `code-evolve eject` | Remove the framework, keep everything the agent built |

### `init`

```bash
code-evolve init                    # basic setup (uses Claude Code by default)
code-evolve init --agent codex      # use Codex CLI instead
code-evolve init --with-ci          # also install GitHub Actions for cloud evolution
code-evolve init --force            # upgrade framework files (preserves journal + learnings)
```

### `vision`

```bash
code-evolve vision           # guided interview to create .evolve/vision.md
code-evolve vision --refine  # revisit and improve an existing vision.md
```

### `migrate`

```bash
code-evolve migrate spec ./docs/technical-spec.md     # regex extraction (no API key needed)
code-evolve migrate spec ./PRD.md --ai                # AI-powered conversion via claude CLI
code-evolve migrate vision ./docs/overview.md         # convert to vision.md format
code-evolve migrate spec ./README.md --ai --yes       # skip confirmation prompt
```

### `start`

```bash
code-evolve start                # every 4 hours (default)
code-evolve start --every 2     # every 2 hours
code-evolve start --run-now     # start now, then repeat on schedule
code-evolve start --model claude-opus-4-6  # use a different model
```

## What Your Project Looks Like

```
my-project/
├── .evolve/
│   ├── vision.md          ← you write this (or use `code-evolve vision`)
│   ├── spec.md            ← you write this (or use `code-evolve migrate`)
│   ├── config.json        ← agent and model settings
│   ├── scripts/           ← orchestration engine (protected)
│   ├── skills/            ← agent behaviors (protected)
│   ├── IDENTITY.md        ← agent constitution (protected)
│   ├── JOURNAL.md         ← the agent's memory
│   ├── LEARNINGS.md       ← cached research
│   └── DAY_COUNT          ← evolution counter
├── src/                   ← the agent builds this
├── tests/                 ← the agent writes these
└── .github/workflows/
    └── evolve/            ← CI workflows (namespaced, won't touch yours)
```

## The Spec Is the Source of Truth

Your `.evolve/spec.md` drives everything. Features are a prioritized checklist:

```markdown
## Features (Priority Order)
- [x] `api serve` — Start the HTTP server
- [x] `api health` — Health check endpoint
- [~] User authentication with JWT
- [ ] Rate limiting middleware
- [ ] WebSocket support for real-time updates
- [ ] Admin dashboard
```

The agent implements them top to bottom. `[x]` = done. `[~]` = in progress. `[ ]` = next up. The agent updates these checkboxes as it works.

## Multi-Agent Support

code-evolve works with multiple AI coding agents:

| Agent | CLI | Flag |
|-------|-----|------|
| Claude Code | `claude` | `--agent claude` (default) |
| Codex CLI | `codex` | `--agent codex` |
| OpenCode | `opencode` | `--agent opencode` |
| Ollama | `ollama` | `--agent ollama` |

```bash
code-evolve init --agent codex        # initialize with Codex
code-evolve run --agent ollama        # one-off run with Ollama
code-evolve start --agent opencode    # schedule with OpenCode
```

The `--agent` flag on `init` is stored in `.evolve/config.json`. Subsequent `run` and `start` commands read from config automatically. You can override with `--agent` on any command.

The default model adapts to your agent (e.g., `llama3` for Ollama, `o4-mini` for Codex). Override with `--model`.

## Stack Detection

Drop code-evolve into any project. It figures out how to build and test it:

| Stack | Detected by | Build | Test | Lint |
|-------|------------|-------|------|------|
| TypeScript | `tsconfig.json` | `npm run build` | `npm run test` | `npm run lint` |
| Next.js | `"next"` in package.json | `npm run build` | `npm run test` | `npm run lint` |
| Python | `pyproject.toml` | `uv sync` | `uv run pytest` | `uv run ruff check .` |
| Rust | `Cargo.toml` | `cargo build` | `cargo test` | `cargo clippy` |
| Go | `go.mod` | `go build ./...` | `go test ./...` | `go vet ./...` |

Package managers (npm, yarn, pnpm, bun) and Python tooling (uv, poetry, pip) are detected automatically.

**Monorepos** are supported automatically. If no stack marker is found at the project root, code-evolve scans immediate subdirectories. When multiple stacks are found (e.g., `backend/` with Python and `frontend/` with Next.js), each substack is verified independently — build, test, and lint run in their respective directories. The post-session fix loop and CI workflow both handle monorepos.

## Local vs. Cloud

Run it however fits your workflow:

**Local** — `code-evolve start`
- Cron job on your machine
- API key stored securely in `.evolve/.env` (mode 600, gitignored)
- Logs in `.evolve/evolve.log`

**Cloud** — `code-evolve init --with-ci`
- GitHub Actions in `.github/workflows/evolve/`
- Runs every 4 hours with 3-attempt retry logic
- Set your agent's API key in repo secrets (`ANTHROPIC_API_KEY` for Claude, `OPENAI_API_KEY` for Codex)

Both run the same engine. Mix and match.

## Community Issues

The agent reads GitHub issues tagged with special labels:

| Label | What it does |
|-------|-------------|
| `agent-input` | Feature requests and bug reports from users — agent prioritizes by vote count |
| `agent-self` | Issues the agent filed for itself — its own backlog for future sessions |
| `agent-help-wanted` | Questions the agent couldn't solve alone — it checks for human replies |

Issue content is treated as untrusted input. The agent analyzes intent but writes its own implementation — it never executes code from issues.

## Safety

The agent is powerful but constrained:

- **Protected files** — `IDENTITY.md`, `scripts/`, `workflows/` cannot be modified by the agent
- **Build verification** — every change must pass build + tests or it gets reverted
- **Automatic rollback** — 3 failed fix attempts = full revert to pre-session state
- **Prompt injection defense** — random boundary markers, HTML comment stripping, body truncation on all issue content
- **Honest journaling** — the agent can't hide failures; the journal is append-only

## Review Before You Ship

code-evolve is powered by AI, and AI-generated code requires human oversight before production use. The agent does its best — it writes tests, verifies builds, and journals its decisions — but it can introduce bugs, security vulnerabilities, or architectural choices that don't fit your context.

**Before deploying or publishing anything the agent built:**
- Review the code changes (`git log`, `git diff`)
- Run your own security review, especially for auth, input handling, and data access
- Test edge cases the agent may not have considered
- Check dependency choices — the agent may pull in packages you haven't vetted
- Read the journal (`.evolve/JOURNAL.md`) to understand *why* decisions were made

The evolution engine is a powerful accelerator, not a replacement for engineering judgment. Treat its output the way you'd treat a pull request from a junior developer: assume good intent, verify thoroughly.

## Upgrading

```bash
npm update -g code-evolve
code-evolve init --force     # updates engine, preserves your evolution history
# or: ce init --force
# Note: --force migrates root-level vision.md/spec.md into .evolve/ automatically
```

## Ejecting

```bash
code-evolve eject    # or: ce eject
```

Stops the engine, removes `.evolve/` and workflows. Your `vision.md` and `spec.md` are copied to the project root. Everything the agent built — your code, tests, docs — stays exactly where it is.

## Requirements

- Node.js >= 18
- Python 3
- Git
- An AI coding agent: [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), [OpenCode](https://github.com/opencode-ai/opencode), or [Ollama](https://ollama.ai)
- API key for your chosen agent (not needed for Ollama)

## Roadmap

- **Skill/plugin format** — install as a Claude Code skill, Codex plugin, etc.
- **GitHub Action** — `uses: frankbria/code-evolve@v1` for zero-install cloud evolution
- **AI video demos** — auto-generate video walkthroughs of each evolution session ([#8](https://github.com/frankbria/code-evolve/issues/8))

## Acknowledgments

Built on the architecture pioneered by [yoyo-evolve](https://github.com/yologdev/yoyo-evolve) by [yologdev](https://github.com/yologdev). The core concepts — autonomous evolution loops, journal-driven memory, spec-driven feature prioritization, and build verification with automatic rollback — originate from that project. code-evolve packages these ideas into a drop-in CLI tool for any project.

## License

[MIT](LICENSE)
