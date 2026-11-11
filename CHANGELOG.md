# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Release workflow**: pushing a `v<version>` tag publishes that version to npm with provenance and
  creates the GitHub release with the plugin ZIP attached (`.github/workflows/release.yml`,
  `scripts/publish-release`). It refuses a tag that does not match `package.json`, and a re-run after
  a partial failure does not publish twice. Maintainer steps are in [INSTALL.md](INSTALL.md) (#95).
- **Version lockstep check**: `node scripts/sync-plugin-version.js --check` fails when a plugin
  manifest or the setup skill's install command is not at `package.json`'s version; CI runs it (#95).
- **Native scheduling** (`--mode native`): cycles run from the agent's own scheduler (a Claude Code
  cloud or Desktop scheduled task, `/loop`, or a Codex scheduled task) instead of cron or GitHub
  Actions. `init --mode native` records the choice and `status` reports it; the `evolve-setup` skill
  and the README give the exact prompt for each scheduler and its constraints (#93).
- **Live acceptance record** for the one-command install and first cycle
  ([docs/demos/first-cycle-acceptance.md](docs/demos/first-cycle-acceptance.md)): both fixtures
  and both install paths on Claude Code (headless sessions), a cron-triggered cycle, and the Codex run from
  2026-11-08, with the defects they turned up (#85).

### Changed
- The `evolve-setup` skill installs the engine version it was written for
  (`npx -y code-evolve@<version> init ...`) instead of `@latest`, so a plugin and the engine it
  installs stay in step. It falls back to `@latest` when that version is not on npm yet, and does
  not put an older engine over a newer one. `npm version` keeps the pinned version current along
  with the plugin manifests (#95).
- `init` says when a switch of mode leaves an earlier cron job or GitHub Actions schedule
  installed, and `start` says when it replaces native scheduling, so two schedulers do not run
  side by side unnoticed. The `evolve-run` skill now checks that the push landed and reports a
  failed push first (#93).

### Fixed
- **Engine papercuts** (#98):
  - A reverted session keeps the lessons it wrote to `.evolve/LEARNINGS.md` and the day counter.
    The revert used to take all of `.evolve/` back with the code, so what a failed session learned
    was lost. Spec checkboxes, the session's own journal entry and requirement edits still go back,
    because they describe work that no longer exists.
  - `code-evolve proof` keeps everything above the first requirement in `REQUIREMENTS.md` (the
    template's format notes, or your own text) when it rewrites the ledger.
  - `proof` and `status` count the first day as Day 0, as the engine does. They used to call it
    Day 1 once a birth date existed, so evidence files and "Satisfied by" lines were a day ahead
    of the journal on the first day.
- Two schedulers working from separate clones (a cloud task or GitHub Actions next to a cron job)
  no longer lose a cycle. Before it pushes, the engine fetches the branch's upstream and rebases the
  session onto what the remote gained, keeping both cycles' journal entries. When the two cycles
  changed the same lines, the rebase is undone and the session's commits stay on the local branch
  (#137).
- A cycle whose push fails is no longer reported as a success: `evolve.sh` (and `code-evolve run`)
  exit with status 4 and end with "committed locally but NOT pushed". The `evolve.yml` workflow
  fails the run instead of starting a new session as a retry, and the session tag is no longer
  pushed when the branch was refused. This includes a branch whose upstream has a different name,
  which git refuses to push by default (#137).
- Two sessions that start in the same minute no longer share one tag: the later one is tagged
  `day<N>-<HH>-<MM>-2` (#137).
- A project that lives in one subdirectory (`app/package.json`, nothing at the root) now has its
  build, test and lint run in that subdirectory, in the baseline check, verification, the cycle
  prompt and the `evolve-ci.yml` workflow. They ran at the project root before and failed.
  `detect_stack.sh` reports such a project as `monorepo` with one substack (#94).
- A cycle on a branch that has no upstream (a fresh repository, or a new branch that was never
  pushed) now pushes the branch and sets its upstream: to the remote git is configured to push to
  (`branch.<name>.pushRemote`, `remote.pushDefault`, `branch.<name>.remote`), else `origin`, else
  the only remote. Before, only the tag reached the remote. With several remotes and nothing to
  choose by, the push is skipped and the command to run is printed; a repository with no remote
  says so in one line. A failed push is reported with git's own reason instead of "maybe no remote
  or auth issue" (#132).
- A Python project without a uv or poetry lock is verified with tools that can run. `pytest` and
  `ruff` are only used when installed (the project's `.venv` first, then `PATH`); a suite made
  only of `unittest.TestCase` classes runs through `python3 -m unittest discover` when pytest is
  missing; and the install step runs as `python3 -m pip install` (or the `.venv`'s Python, or
  `uv pip install` for a `.venv` without pip) and is left out where that Python has no pip or is
  externally managed (PEP 668) with no virtual environment. Before, a standard-library project on a stock Ubuntu Python failed
  its first verification on `pip`, `pytest` and `ruff` alone. The `evolve-ci.yml` workflow reads
  the commands after it installs dependencies, for a root project and for nested ones (#133).
- Ruff and deno checks skip `.evolve/`, `.claude/` and `.agents/`. `ruff format --check .` used to
  fail on the engine's own scripts in any project that had ruff, and the automatic format fix then
  rewrote those protected files (#133).

## [0.2.0] — 2026-06-29

The guided-install release: `code-evolve` goes from "happy-path engine" to a
drop-into-any-repo tool with a full onboarding wizard, broad stack support, and a
passing test suite.

### Added
- **`setup` wizard** — one command chains agent/auth picker → vision + spec
  interviews → execution mode → schedule → ready (#45).
- **`spec` command** — guided interview that generates `.evolve/spec.md` (#40).
- **`vision`/`spec` interviews are LLM-driven** via the configured agent, and
  `init` offers to run them right after install (#41, #42).
- **Interactive agent + auth picker** on `init` (TTY) (#39).
- **Execution-mode selector** (`--mode local|ci|both`), persisted in config (#43).
- **Configurable schedule at install** — `--every <hours>` applies to both the
  local cron and the templated CI workflow (#44).
- **Agent-aware CI** — the bundled `evolve.yml` is templated per backend (CLI
  install, `AGENT`/`MODEL`, the right secret); CI provisions Rust/Go/JVM
  toolchains for the detected stack (#46, #52).
- **Stack detectors** for Deno, Java/Kotlin, C#/.NET, Ruby, PHP, C/C++, and
  static sites, on top of the existing JS/TS, Python, Rust, Go, and Make support (#47).
- **PROOF9** optional requirements-ledger / quality-gate subsystem and `proof`
  command (#14).
- **Jest unit suite** and a fixed `npm test` (#53).
- **Docs**: `AGENTS.md` (canonical agent guide), `INSTALL.md`, and this changelog.

### Changed
- **Greenfield repos are supported** — a fresh `git init` with zero commits now
  bootstraps without aborting; `evolve.sh` seeds a baseline commit first (#38).
- **Non-Claude adapters verified** against current CLIs: `codex exec`,
  `opencode run -m provider/model`, `ollama run` (#50).
- **Agent error detection is per-adapter** — no longer assumes Claude's JSON
  shape; honors real exit codes (#49).
- **Build/test/format invocation is stack-aware** — dropped the blind `--quiet`
  that produced false build failures for Go/Make/pip (#48).
- **Skills respect existing conventions** when adopting a mature repo (#51).
- CLI version is now read from `package.json` (single source of truth).
- `CLAUDE.md` slimmed to import `AGENTS.md`; README command table completed;
  `schedule.json` documented as display-only and `--force` help corrected (#54, #55).

### Fixed
- GitHub Actions workflows install directly into `.github/workflows/` (with
  collision-safe `evolve-*` names) so they actually run (#36).

## [0.1.0] — 2026-03-14

Initial npm release. Core evolution engine: `init`/`run`/`start`/`stop`/`status`/
`eject`/`migrate`, `.evolve/` scaffold, data-driven stack detection, collision-safe
install, local cron + CI execution, multi-agent backend architecture
(claude/codex/opencode/ollama), and the `vision` interview.

[0.2.0]: https://github.com/frankbria/code-evolve/releases/tag/v0.2.0
[0.1.0]: https://github.com/frankbria/code-evolve/releases/tag/v0.1.0
