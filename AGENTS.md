# AGENTS.md

Canonical, agent-agnostic guide for any AI coding agent (Claude Code, Codex,
OpenCode, Cursor, etc.) working **on this repository**. `CLAUDE.md` imports this
file — keep project guidance here, not duplicated there.

> This is guidance for developing the **code-evolve package itself**. It is not
> the runtime that code-evolve installs into a user's project (that lives in
> `templates/` and `.evolve/`).

## What This Is

An npm CLI package (`code-evolve`) that turns any project into a self-evolving
codebase. Users run `npx code-evolve init` in their project, fill in
`.evolve/vision.md` and `.evolve/spec.md`, and the framework autonomously builds
and improves the project session after session using an AI coding agent
(Claude Code by default; Codex, OpenCode, Ollama, and any headless CLI through a custom command template are also supported).

## Repository Structure

```
code-evolve/                  # npm package source
├── package.json              # npm package config (bin: code-evolve, ce)
├── tsconfig.json             # TypeScript config
├── jest.config.js            # Jest (ts-jest) config
├── README.md, INSTALL.md     # User docs (quickstart, install and troubleshooting); CHANGELOG.md
├── src/                      # CLI source (TypeScript)
│   ├── cli.ts                # Entrypoint (commander)
│   ├── commands/             # One file per subcommand (see Commands below)
│   │   ├── init.ts           # code-evolve init (exports runInit)
│   │   ├── bootstrap.ts      # bare `code-evolve`: init --yes, then open the agent on evolve-setup
│   │   ├── setup.ts          # code-evolve setup (re-runnable init)
│   │   ├── start.ts          # code-evolve start (set up recurring cron)
│   │   ├── stop.ts           # code-evolve stop (remove cron)
│   │   ├── run.ts            # code-evolve run
│   │   ├── status.ts         # code-evolve status
│   │   ├── eject.ts          # code-evolve eject
│   │   ├── migrate.ts        # code-evolve migrate
│   │   ├── retiredInterviews.ts # code-evolve vision / spec: pointers to evolve-setup (retired, #97)
│   │   ├── proof.ts          # code-evolve proof (PROOF9 quality gates)
│   │   └── upgrade.ts        # code-evolve upgrade (managed engine files only)
│   └── utils/
│       ├── paths.ts          # Path resolution
│       ├── checks.ts         # Dependency checking
│       ├── output.ts         # TTY/JSON output
│       ├── agent.ts          # Agent backend invocation
│       ├── config.ts         # Agent/mode selection + config I/O
│       ├── migrate.ts        # Spec/vision document migration
│       ├── proof.ts          # PROOF9 requirements management
│       └── __tests__/        # Jest unit tests
├── tests/                    # Shell tests (test_*.sh) driving the built CLI and engine scripts
├── .claude-plugin/marketplace.json  # The repo is its own Claude Code marketplace (serves plugins/code-evolve)
├── plugins/code-evolve/      # Self-contained plugin: plugin.json (Agent Plugins 1.0, Codex etc.) + .claude-plugin/plugin.json; versions synced by `npm version`
│   ├── assets/               # logo.png, composer-icon.png
│   ├── hooks/                # hooks.json (Claude Code; Codex via plugin.json): PreToolUse protected-files guard, SessionStart setup/upgrade nudge
│   └── skills/               # Operator skills (evolve-setup/-run/-status); init copies them into .claude/skills + .agents/skills
├── templates/                # Files installed by `init` into a target project
│   ├── scripts/              # evolve.sh, detect_stack.sh, unittest_suite.py, format_issues.py, hold_lock.py, agents/ (per-backend adapters)
│   ├── skills/               # Runtime skills (6 dirs, Agent Skills SKILL.md format; indexed into the cycle prompt)
│   ├── state/                # IDENTITY.md, JOURNAL.md, LEARNINGS.md, REQUIREMENTS.md, DAY_COUNT, vision.md, spec.md
│   └── workflows/            # GitHub Actions (evolve.yml, ci.yml)
├── scripts/                  # Repo tooling: sync-plugin-version.js (npm version hook; --check for CI), pack-codex-plugin (plugin ZIP; `--directory` for the hook-free copy for OpenAI's public directory), publish-release (run by release.yml)
├── docs/                     # STATUS.md, PROOF9.md, demos/ (live acceptance records); support/privacy/terms pages for GitHub Pages (_config.yml)
├── dist/                     # Compiled output (gitignored; built on publish)
└── .github/workflows/        # CI for this package; release.yml stages a release on npm for a pushed v<version> tag
```

## Commands

The CLI ships 12 subcommands (registered in `src/cli.ts`; also available as `ce`):

| Command | Purpose |
|---------|---------|
| `init` | Initialize `.evolve/` in the current project |
| `setup` | Re-runnable `init`: reconfigures an existing install from flags |
| `start` | Start the evolution engine (sets up a recurring local cron job) |
| `stop` | Stop the evolution engine (removes the local cron job) |
| `run` | Run one evolution cycle |
| `status` | Show current evolution state |
| `eject` | Remove code-evolve framework, keep project files |
| `migrate` | Convert an existing spec or vision document into code-evolve format |
| `vision`, `spec` | Retired: print a pointer to the `evolve-setup` skill |
| `proof` | PROOF9 quality gates and requirements management |
| `upgrade` | Replace the managed engine files with this version's; user-owned files are kept (needs a clean git tree) |

With no subcommand, `code-evolve` bootstraps: it picks the agent CLI on PATH, runs
`init --yes --agent <it>`, then execs that agent with the `evolve-setup` skill as its first prompt.

## Development

```bash
npm install           # Install dependencies
npm run build         # Compile TypeScript to dist/ (prepends shebang, chmods bin)
npm run dev           # Watch mode
npm run lint          # Type-check without emitting (tsc --noEmit)
npm test              # Jest unit suite, then every tests/test_*.sh against a fresh build
npm run test:shell    # Shell tests only (builds first; they drive dist/cli.js)
```

Installation and publishing are documented in [INSTALL.md](INSTALL.md).

## How It Works (User Perspective)

1. The user starts from one of four doors: `npx code-evolve` in a terminal, the Claude Code plugin,
   the Codex (Agent Plugins) plugin, or `npx skills add frankbria/code-evolve` for any other agent.
2. Every door ends in the `evolve-setup` operator skill. It runs `init --yes` (the materializer),
   drafts `.evolve/vision.md` and `.evolve/spec.md` from the repository, asks at most five
   questions, and sets up how cycles run: cron (`start`), GitHub Actions (`--mode ci`), the agent's
   own scheduler (`--mode native` + the `evolve-run` skill), in-session, or `code-evolve run`.
3. Each cycle runs `.evolve/scripts/evolve.sh`: the agent reads the vision and spec, builds the
   next feature, the engine verifies it (reverting on failure), journals, commits, tags and pushes.

## Architecture

- **One engine, thin shells.** `.evolve/` (engine + state) is vendored into the user's repository,
  so CI, collaborators and headless agents work with no plugin installed. Plugins and skills are
  entry points to it, not a second engine.
- **Materializer.** `init` (which `setup` and `upgrade` call) is the only code that writes the install: `.evolve/` from `templates/`,
  the operator skills into `.claude/skills/` and `.agents/skills/`, a managed section in the
  project's `AGENTS.md`/`CLAUDE.md`, `.gitignore` lines, and optionally the workflows or a cron job.
  `init` never prompts (#97); `upgrade` replaces only the managed files (#88).
- **Engine phases.** `evolve.sh cycle` (the default) is the headless run through an adapter in
  `templates/scripts/agents/` (claude, codex, opencode, ollama, custom). `prepare` / `verify` /
  `finalize --no-agent` let an agent drive a cycle from inside its own session (`evolve-run`),
  with state in `.evolve/run/`.
- **Two kinds of skills.** Operator skills (`plugins/code-evolve/skills/`: `evolve-setup`,
  `evolve-run`, `evolve-status`) are for the user's agent; init copies them into the project.
  Runtime skills (`templates/skills/`) are for the cycle's agent and are indexed into the cycle prompt.
- **Manifests.** `plugins/code-evolve/.claude-plugin/plugin.json` (Claude Code) and
  `plugins/code-evolve/plugin.json` (Agent Plugins 1.0, with OpenAI listing metadata under
  `extensions["com.openai"]`) describe the same plugin folder; `.claude-plugin/marketplace.json` at
  the root makes the repository its own marketplace. `npm version` keeps both manifest versions in
  step with `package.json` (`scripts/sync-plugin-version.js`; CI runs it with `--check`).
- **Hooks** (`plugins/code-evolve/hooks/`): a PreToolUse guard for protected files and a
  SessionStart nudge (set up, or upgrade on version drift). The engine's restore after every agent
  call is the enforcement; the hook only stops edits earlier.

## Key Design Decisions

- **`.evolve/` namespace**: All framework files live in `.evolve/` to avoid polluting the project root
- **`PROJECT_DIR=.`**: The project being built IS the repo root (not a subdirectory)
- **`EVOLVE_DIR` env var**: All paths in `evolve.sh` are relative to this variable
- **Engine phases**: `evolve.sh [cycle|prepare|verify|finalize [--no-agent]]`. `cycle` (default) is the headless run; `prepare` / `verify` / `finalize --no-agent` let an agent drive a cycle from inside its own session, with state in `.evolve/run/`
- **Templates shipped with npm package**: `init` copies from `node_modules/code-evolve/templates/`
- **vision.md and spec.md in .evolve/**: User documents live alongside other state files to avoid filename collisions

## Protected Files (in templates)

These must not be modified by the evolution agent. The canonical list is
`templates/scripts/protected-paths.txt` (installed as `.evolve/scripts/protected-paths.txt`);
`evolve.sh` snapshots those paths at session start and restores them after every agent call.

- `.evolve/IDENTITY.md` — agent constitution
- `.evolve/scripts/evolve.sh` — orchestrator
- `.evolve/scripts/format_issues.py` — input sanitization
- `.evolve/scripts/hold_lock.py` — single-run lock (keeps two cycles from editing the repo at once)
- `.evolve/scripts/*` and `.evolve/skills/*` — the rest of the engine and the runtime skills
- `.github/workflows/evolve.yml` — auto-evolution workflow
- `.github/workflows/evolve-ci.yml` — CI/CD safety net (installed by `init --with-ci` from `templates/workflows/ci.yml`, renamed so it never clobbers the target repo's own `ci.yml`)
