# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Live acceptance record** for the one-command install and first cycle
  ([docs/demos/first-cycle-acceptance.md](docs/demos/first-cycle-acceptance.md)): both fixtures
  and both install paths on Claude Code, a cron-triggered cycle, and the Codex run from
  2026-11-08, with the defects they turned up (#85).

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
