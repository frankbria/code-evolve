# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Nested projects next to a root project**: list their directories in
  `.evolve/nested-projects.txt` (one per line) and the baseline check, the cycle prompt,
  verification and the installed CI workflow run each one's build, test and lint in its own
  directory, in addition to the root project. Nothing changes without the file: the root project
  alone is verified, and the engine now names the nested folders with a stack marker that it does
  not verify (`Not verified: api/`), without running anything in them. Without a root project, the list adds projects deeper
  than one level. `detect_stack.sh` reports listed projects as `substacks` and the unlisted ones
  as `unverified` (#152).
- **Release workflow**: pushing a `v<version>` tag publishes that version to npm with provenance and
  creates the GitHub release with the plugin ZIP attached (`.github/workflows/release.yml`,
  `scripts/publish-release`). It refuses a tag that does not match `package.json`, and a re-run after
  a partial failure does not publish twice. Maintainer steps are in [INSTALL.md](INSTALL.md) (#95).
- **Upload copy for OpenAI's public plugin directory**: `scripts/pack-codex-plugin --directory`
  builds the plugin ZIP without the hooks and without their entry in `plugin.json`, because the
  directory does not take plugins with lifecycle hooks. It names the listing pages the manifest
  still lacks. The release ZIP is unchanged. Maintainer steps are in [INSTALL.md](INSTALL.md) (#100).
- **Version lockstep check**: `node scripts/sync-plugin-version.js --check` fails when a plugin
  manifest or the setup skill's install command is not at `package.json`'s version; CI runs it (#95).
- **Native scheduling** (`--mode native`): cycles run from the agent's own scheduler (a Claude Code
  cloud or Desktop scheduled task, `/loop`, or a Codex scheduled task) instead of cron or GitHub
  Actions. `init --mode native` records the choice and `status` reports it; the `evolve-setup` skill
  and the README give the exact prompt for each scheduler and its constraints (#93).
- **Recorded GitHub Actions run** of the installed `evolve.yml` with a refused push
  ([docs/demos/refused-push-on-actions.md](docs/demos/refused-push-on-actions.md)): the session ends
  with status 4, both retries are skipped and the run fails (#145).
- **Live acceptance record** for the one-command install and first cycle
  ([docs/demos/first-cycle-acceptance.md](docs/demos/first-cycle-acceptance.md)): both fixtures
  and both install paths on Claude Code (headless sessions), a cron-triggered cycle, and the Codex run from
  2026-11-08, with the defects they turned up (#85).

### Changed
- **A cycle whose protected files could not be checked ends with exit status 5** (#150). When the
  directory behind one of your protected symlinks has been swapped for a symlink to another
  directory, the engine still leaves everything behind it alone and prints the warning, and the
  cycle still commits and pushes, but it no longer ends with status 0. `code-evolve run` passes
  the status on and the `evolve.yml` workflow fails the run without retrying (a new session would
  take the swapped directory for your layout). Run `code-evolve upgrade` to get the new workflow.
- **A session refuses names the guard's snapshot cannot hold** (#150): it stops with exit status 1
  before the agent runs when a symlinked protected directory has a tab or newline in its name, its
  target or the path it leads to, or a protected path has a newline in its name. These used to be recorded wrongly.
- A cycle starts from its upstream's state: `evolve.sh` (`cycle` and `prepare`) fetches the branch's
  upstream first, fast-forwards a branch that is behind and rebases cycles that were never pushed (a branch that
  is pushed to a fork is only ever fast-forwarded).
  When it cannot (a conflict, uncommitted edits in the way, an unreachable remote) it prints the
  reason and the cycle starts from the local branch as before (#145).
- Issue comments are posted after the push and cite the commit that is on the remote; they used to
  cite the commit as it was before the rebase. A cycle whose commits reached no remote (not pushed,
  or the push was skipped for lack of a chosen remote or a branch) posts no comment and closes no
  issue; those responses are dropped (#145).
- The `evolve-setup` skill installs the engine version it was written for
  (`npx -y code-evolve@<version> init ...`) instead of `@latest`, so a plugin and the engine it
  installs stay in step. It falls back to `@latest` when that version is not on npm yet, and does
  not put an older engine over a newer one. `npm version` keeps the pinned version current along
  with the plugin manifests (#95).
- `init` on an existing install (`--yes`, `--force`, or through `setup`) refuses to put its engine
  over a newer installed one, as `upgrade` already did: when `engineVersion` in
  `.evolve/config.json` is newer than the code-evolve that was run, it exits 1, changes nothing and
  says to use a newer code-evolve or update the plugin. An out-of-date plugin or skill copy can no
  longer downgrade the engine. The `evolve-setup` skill still compares the versions first, because
  the 0.2.0 already on npm has no such check, and tells the user to update the plugin when init
  refuses (#140).
- `init` says when a switch of mode leaves an earlier cron job or GitHub Actions schedule
  installed, and `start` says when it replaces native scheduling, so two schedulers do not run
  side by side unnoticed. The `evolve-run` skill now checks that the push landed and reports a
  failed push first (#93).

### Fixed
- `--agent-env` with a name every JavaScript object has (`constructor`, `toString`, `__proto__`)
  no longer breaks scheduling. Such a name was read as set even when the shell did not set it, so
  `init --mode local` and `start` ended with `Could not install local cron job: value.replace is
  not a function` and `run` handed the agent a variable holding JavaScript source. It is now a
  variable like any other: saved when the shell exports it, reported as not set when it does not (#154).
- A nested project whose directory name contains `|` is verified in its directory. The engine
  split its `dir|build|test` lines on that character, so the baseline check and verification ran
  `cd` on half the name and the session could only be reverted (#152).
- **Protected-files guard leftovers** (#150):
  - A file or directory with a newline in its name that the agent plants under a protected path is
    removed like any other planted file. It used to survive.
  - A protected symlink repointed to a name that differs only by trailing newlines is put back; the
    comparison used to see the two as equal.
  - Outside a git repository, an engine run with an absolute `EVOLVE_DIR` outside the project
    stopped with a `cd: No such file or directory` error while placing the run lock.
  - CI runs the guard's test on macOS (BSD `find`, bash 3.2) as well as on Linux.
- **Day count and ledger leftovers** (#147):
  - `code-evolve status` prints the same day as `code-evolve proof` in every state. Before the
    first cycle it used to print 0 from `.evolve/DAY_COUNT` while `proof` counted from the birth
    date.
  - `init` records the birth date on the local calendar, the one the engine counts from. It used
    to write the UTC date, so a project set up east of UTC in the early morning started on Day 1.
    The engine now writes Day 0 for a birth date that is a day or more in the future (a clock that
    was set back); it used to write a negative day.
  - `proof` keeps the text you add under a requirement in `REQUIREMENTS.md` (notes, your own
    `- **Field**: value` lines, sub-headings, fenced examples) when it rewrites the ledger; it is
    written back below the requirement's fields. A second line for a field the requirement already
    has is kept there too. A field left empty is no longer read back as the line below it.
  - A reverted session that created `.evolve/LEARNINGS.md` and left it uncommitted keeps it in
    the revert commit only. It used to be stashed as well, and `git stash pop` then refused
    because the file already existed.
- A push that git reports as done without sending the cycle's branch (a `remote.<name>.push`
  mapping or a `push.default` that leaves it out) now ends the cycle as not pushed, with exit
  status 4 (#145).
- A remote with one push URL that differs from its fetch URL: the cycle is synced with the push URL's
  repository, the one that accepts or refuses the push. It used to be rebased onto the fetch side
  (#145).
- **Python test detection reads the test files instead of matching lines.** Whether a suite can
  run through `python3 -m unittest discover` is now decided by parsing each test file (new engine
  file `.evolve/scripts/unittest_suite.py`): a pytest function written as `def test_x ():` or
  defined under `try`, a `Test*` class that is not a `unittest.TestCase` and has or may inherit a
  test, a test file that imports pytest, or a `load_tests` hook keeps `pytest`; `TestCase` under
  another import name, a base class of the same file, and mixins are recognised. Test packages below the start directory (`tests/unit/`,
  `app/tests/`, with `__init__.py` at each level) now run through unittest instead of failing with
  "pytest: command not found" (#143).
- A project `.venv` without pytest no longer uses a pytest found on `PATH`, which ran on another
  Python. A unittest suite runs on the `.venv` python; a pytest suite gets
  `.venv/bin/python -m pytest`, which reports the missing module (#143).
- uv and poetry projects get `uv run pytest` / `poetry run ruff ...` only when the lock file names
  the tool. Without pytest in the lock, a unittest suite runs as `uv run python -m unittest
  discover` and a project with no tests gets no test command; without ruff in the lock, the ruff
  of `.venv` or `PATH` is used, or lint and format are skipped (#143).
- The Deno lint and format commands are now run with a real deno next to a fresh `.evolve/` in
  this repository's tests, and the installed CI workflow's "Detect and verify project" step has
  a test of its own. The section `init` writes into `AGENTS.md` is now wrapped at 80 columns with
  blank lines around its markers, the way `deno fmt` writes Markdown, and `deno fmt --check`
  passes on it; an existing section is rewritten by the next `init` or `upgrade` (#143).
- **Papercuts from the live Claude acceptance runs** (#134):
  - `start` run through `npx` no longer saves npm's own `PATH` entries into `.evolve/.env`: the npx
    cache's `node_modules/.bin` (gone once the cache is cleaned), the `node_modules/.bin` of the
    project and each parent directory, and `node-gyp-bin`. An entry that holds the agent's binary
    is kept, so an agent CLI installed in the project still runs from cron. The rest of `PATH` is
    saved unchanged.
  - The `evolve-setup` skill can tell a headless run (`claude -p`, `codex exec`, `opencode run`,
    `CLAUDE_CODE_ENTRYPOINT` starting with `sdk`) and then asks nothing: it uses its recommended
    answers, settles on cycles run inside an agent session or manually, installs no schedule, and
    ends with what it assumed instead of a question.
  - The first cycle commits a new install on its own (`code-evolve: add the engine and setup
    files`) before the session starts, so the first feature commit holds only the feature. The
    commit takes only what `init` wrote (`.evolve/`, the code-evolve skills, the code-evolve
    section's `AGENTS.md` / `CLAUDE.md`, `.gitignore`, the evolve workflows); other uncommitted
    work is left as it was, and an `AGENTS.md`, `CLAUDE.md` or `.gitignore` that also has your own
    uncommitted edits is left out with a note. It applies to `evolve.sh prepare` and to a headless
    cycle, once, when nothing under `.evolve/` is committed yet. An install kept out of git by an
    ignore rule is not committed, and nothing is committed during an unfinished merge. Cycles
    that run from the remote (GitHub Actions, a cloud scheduled task) still need the install
    committed and pushed by you.
- **`start` keeps a custom agent's saved credential** (#130). When a variable named with
  `--agent-env` is not set in the shell that runs `code-evolve start` (or an `init` that reinstalls
  the schedule), the value already in `.evolve/.env` is kept instead of being dropped, so scheduled
  cycles keep authenticating. `start` now warns for each such variable, and says when no value is
  saved either. `start --run-now` uses the kept value for its first cycle.
- **In-session cycles keep every check they find** (#113). `evolve.sh verify` now saves the build,
  test and lint commands and the nested projects it finds to `.evolve/run/session.env`. A check
  that first appears during the session (a new `package.json`, a new `app/` project) is run again
  by every later `verify` and by `finalize`, even if the session has since removed the script, so
  removing a failing check no longer makes the session pass. Until the session ends, a check that
  was found can only be fixed, not dropped. Verification also runs a nested project that replaces
  a root with nothing to run (a static `index.html`), which was skipped before.
- **Protected-files guard, two layouts it missed** (#109):
  - A protected directory you keep as a symlink (for example `.evolve/skills` pointing at a shared
    store, or one skill directory inside it) is now followed when the session starts. Files
    behind the link are restored after an agent call, files planted there are removed, and a
    link the agent repoints or deletes goes back on its original target. A directory symlink
    the agent adds is removed without being followed. If the directory a link leads to has itself
    been swapped for another (the link's own text is unchanged), the engine prints a warning and
    leaves everything behind that link alone rather than write into an unrelated directory.
  - An engine run by hand with an absolute `EVOLVE_DIR` is guarded. A path inside the project is
    reduced to its relative form (so `prepare` also writes its state under `.evolve/run/` rather
    than a stray nested directory); a path outside the project is guarded in place. Nothing was
    snapshotted in either case before. `code-evolve run` always passed the relative path.
- **Engine papercuts** (#98):
  - A reverted session keeps the lessons it wrote to `.evolve/LEARNINGS.md` and the day counter.
    The revert used to take all of `.evolve/` back with the code, so what a failed session learned
    was lost. Spec checkboxes, the session's own journal entry and requirement edits still go back,
    because they describe work that no longer exists.
  - `code-evolve proof` keeps everything above the first requirement in `REQUIREMENTS.md` (the
    template's format notes, or your own text) when it rewrites the ledger.
  - `proof` and `status` count the first day as Day 0, as the engine does. They used to call it
    Day 1 once a birth date existed, so evidence files and "Satisfied by" lines were a day ahead
    of the journal on the first day. A birth date is read as local midnight, as the engine reads it.
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
