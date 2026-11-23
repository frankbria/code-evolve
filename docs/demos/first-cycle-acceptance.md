# Acceptance demo: fresh repo → one command → first evolution cycle

This is the live record for [#85](https://github.com/frankbria/code-evolve/issues/85), the
end-to-end proof for the cross-agent plugin epic ([#99](https://github.com/frankbria/code-evolve/issues/99)).
Every command below was run against real agents; nothing here is inferred from the test suite.
Long outputs are shortened to the lines that matter.

**Where it stands (2026-11-16):** on both Claude Code and Codex, both fixtures went from install
to a verified, committed first cycle through both install paths (on the mature fixture, Codex's
plugin run had `init` run in a terminal first). A cron-triggered cycle (Claude
Code) committed and pushed on its own. Bare `npx code-evolve`, typed in a real terminal, handed
off to each agent's terminal UI, and `evolve-setup` ran there with a person answering its
questions; those two passes stopped after setup
([2026-11-16](#codex-matrix-and-the-interactive-hand-off-2026-11-16)). These runs turned up
three defects: one is fixed in the PR that added this section, and two are filed as issues
([Defects found](#defects-found)).

| Agent | Fixture | Install path | Setup | First cycle | Result |
|---|---|---|---|---|---|
| Claude Code | mature | B: plugin | drafted 4 features | 7 commits, 13/13 tests | passed, tag and branch pushed |
| Claude Code | empty | B: plugin | drafted 10 features | 10 commits, 41/41 tests | passed, but only the tag was pushed ([#132](https://github.com/frankbria/code-evolve/issues/132)) |
| Claude Code | empty | A: `npx code-evolve`, headless | drafted 11 features | 10 commits, 42/42 tests | passed, but only the tag was pushed ([#132](https://github.com/frankbria/code-evolve/issues/132)) |
| Claude Code | mature | A: `npx code-evolve`, headless | drafted 5 features | 7 commits, 23/23 tests | passed, tag and branch pushed |
| Claude Code | mature | cron, `start --every 1` | drafted 5 features | 8 commits, 15/15 tests | passed unattended at 02:00 UTC, tag and branch pushed |
| Codex | mature | B: plugin, after `init` in a terminal | done | `tasklite done <id>`, 7/7 tests | passed on 2026-11-08, tag and branch pushed |
| Codex | empty | A: `npx code-evolve`, headless | drafted 6 features (after one answer) | 7 commits, 3/3 tests, scaffold only | passed on 2026-11-16, tag and branch pushed |
| Codex | empty | B: plugin only (setup ran init) | drafted 7 features | 10 commits, 17/17 tests | passed on 2026-11-16 with `~/.npm` writable ([#182](https://github.com/frankbria/code-evolve/issues/182)), tag and branch pushed |
| Codex | mature | A: `npx code-evolve`, headless | drafted 3 features | 6 commits, 8/8 tests | passed on 2026-11-16, tag and branch pushed |
| Claude Code | mature | A: `npx code-evolve`, interactive terminal UI | 3 questions answered | not run (setup only) | `evolve-setup` ran in the terminal UI |
| Codex | mature | A: `npx code-evolve`, interactive terminal UI | 3 questions answered | not run (setup only) | `evolve-setup` ran in the terminal UI |

For the cycle rows, "passed" means the engine's own `verify` passed, `finalize` committed and
tagged the session, the working tree was clean afterwards, and the project's test suite passes
when run by hand.

## What was run

- **Build under test:** `main` at `c76bcca`, packed with `npm pack`. npm still serves the 0.2.0
  published in June, which has no `init --yes`, so `npx code-evolve` and `npx code-evolve@latest`
  were made to resolve to the packed build through a private npx cache (`npm_config_cache`). This
  is the only substitution. It goes away with the next release ([#95](https://github.com/frankbria/code-evolve/issues/95)).
- **Agent:** Claude Code 2.1.322, signed in with a Claude subscription (no `ANTHROPIC_API_KEY`).
  The in-session runs used the CLI's default model (`claude-fable-5-2`); the cron run used
  code-evolve's default for Claude (`claude-sonnet-4-6`).
  Host: Ubuntu 24.04, Node 24.12, Python 3.12, running as root.
- **Fixtures**, each with a local bare repository as `origin`:
  - **empty:** `git init` and `git remote add origin`, with no commits and no files.
  - **mature:** `tasklite`, a small Node task-list CLI with `add` and `list`, three `node:test`
    tests, a README roadmap of three unbuilt commands, one commit, pushed.
- **Sessions:** every Claude session was started from a clean environment as

  ```bash
  claude -p "<prompt>" --permission-mode dontAsk \
    --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Skill" --strict-mcp-config --output-format json
  ```

  Nobody answered questions, so setup used its own recommended answers. For the empty fixture the
  idea was given with the prompt, since an empty repository has nothing to draft from:

  > I want to build "uconv", a small Python 3 command-line unit converter for people who work in a
  > terminal: `uconv 10 km mi` prints the converted value. Lengths (m, km, mi, ft) and temperatures
  > (C, F, K) to start with; standard library only, tested with unittest.

Times and costs are what `claude -p` reported (the cost is its API-price estimate; the runs were
on a subscription).

| Session | Turns | Time | Cost |
|---|---|---|---|
| mature, plugin: setup / cycle | 8 / 7 | 40 s / 63 s | $0.60 / $0.85 |
| empty, plugin: setup / cycle | 6 / 27 | 42 s / 306 s | $0.58 / $2.75 |
| empty, npx: setup / cycle | 4 / 22 | 35 s / 236 s | $0.55 / $2.03 |
| mature, npx: setup / cycle | 6 / 10 | 48 s / 99 s | $0.63 / $1.06 |
| mature, cron: setup | 6 | 42 s | $0.60 |

## Path B: the Claude Code plugin

The plugin was loaded from the repository with `--plugin-dir plugins/code-evolve`, which is what
`/plugin install code-evolve` provides once the marketplace is added.

### Mature fixture

```bash
claude -p "/code-evolve:evolve-setup" --plugin-dir <code-evolve>/plugins/code-evolve ...
claude -p "/code-evolve:evolve-run"   --plugin-dir <code-evolve>/plugins/code-evolve ...
```

Setup installed the engine with `npx -y code-evolve@latest init --yes --agent claude`, read the
repository, and wrote a vision and a spec whose checklist is the README roadmap plus "keep the
usage message and README in step". It left the crontab alone and committed nothing.

The cycle built all four items. From its report:

> The Day 0 cycle finished cleanly: all four spec features are built, verification passed, and the
> session is committed, tagged `day0-01-20` and pushed. [...] The test suite grew from 3 to 13 tests.

```
$ git log --format='%h %s'
0005459 Day 0 (01:20): session wrap-up
e762297 Day 0 (01:20): journal entry
ced6883 Day 0 (01:20): update spec progress
bd3892f Day 0 (01:20): document done, rm and list --pending in README
84a682e Day 0 (01:20): add 'list --pending' filter
f9fdbf6 Day 0 (01:20): add 'rm <id>' command
6dcd3d2 Day 0 (01:20): add 'done <id>' command
79cac42 tasklite: add and list
$ git ls-remote origin
00054599…  refs/heads/main
ef8d0cb1…  refs/tags/day0-01-20
$ npm test        # tests 13, pass 13, fail 0
$ git status --short        # (clean)
```

### Empty fixture

```bash
claude -p "/code-evolve:evolve-setup <the idea above>" --plugin-dir <code-evolve>/plugins/code-evolve ...
claude -p "/code-evolve:evolve-run" --plugin-dir <code-evolve>/plugins/code-evolve ...
```

Setup counted the idea as the first of its five questions, drafted a ten-item checklist, and
wrote its four remaining assumptions (output format, case-insensitive units, extras, packaging)
into the spec. The engine seeded the repository's first commit, and the cycle built the whole
project:

```
$ git log --format='%h %s'
16b0de6 Day 0 (01:22): session wrap-up
61d2653 Day 0 (01:22): update proof obligations and journal
ab028b0 Day 0 (01:22): dev tooling (uv lockfile, pytest runner, ruff) so engine verification can run
a833a7f Day 0 (01:22): journal entry
6508599 Day 0 (01:22): update spec progress
103ef07 Day 0 (01:22): README with install, usage and unit table
5b500be Day 0 (01:22): CLI with output format, errors, --help, --version, --list, --precision
60bf8cb Day 0 (01:22): temperature conversion through kelvin
cda4441 Day 0 (01:22): project skeleton and length conversion
f4b4300 code-evolve: initial commit
$ python3 -m unittest discover        # Ran 41 tests ... OK
$ git ls-remote origin
5003689d…  refs/tags/day0-01-22          # the tag only: main was not pushed (#132)
```

Two defects showed up here and again in the other empty-repo run:

- **The branch was not pushed.** A repository that starts with no commits has no upstream for
  `main`, and the engine's plain `git push` fails on that while the tag push succeeds
  ([#132](https://github.com/frankbria/code-evolve/issues/132)).
- **The first `verify` failed on tooling, not code.** For a `pyproject.toml` the engine runs
  `pip install -e .`, `pytest` and `ruff`. The stock Python is externally managed, so pip refuses
  the install, and pytest and ruff are not installed. Ruff is also pointed at the engine's own
  scripts under `.evolve/`: the agent's `ruff format .` rewrote two of them, the plugin's guard
  hook blocked it from editing them back, and `finalize` restored them. The agent added a
  `uv.lock` and a dev dependency group to get verification running, and recorded that as
  REQ-0001 ([#133](https://github.com/frankbria/code-evolve/issues/133)).

## Path A: `npx code-evolve`

Bare `code-evolve` installs with the agent it finds and then starts that agent on the
`evolve-setup` skill. Without a terminal it prints the equivalent commands instead:

```
$ npx -y code-evolve < /dev/null
To set up code-evolve, run one of these in your project:

  npx code-evolve init --yes --agent claude && claude /evolve-setup
  npx code-evolve init --yes --agent codex && codex '$evolve-setup'
  npx code-evolve init --yes --agent opencode && opencode --prompt 'Use the evolve-setup skill to set up code-evolve in this project.'
```

Both fixtures ran the first of those lines, with `claude -p` in place of the interactive
`claude`, and then the project-level skills that `init` copies into `.claude/skills/`:

```bash
npx code-evolve init --yes --agent claude
claude -p "/evolve-setup" ...        # empty fixture: "/evolve-setup <the idea above>"
claude -p "/evolve-run" ...
```

```
$ npx code-evolve init --yes --agent claude
Checking dependencies...
  ✓ python3 (Python 3.12.3)
  ✓ git (git version 2.43.0)
  ✓ claude (2.1.322 (Claude Code))

Creating .evolve/ directory...
  Updated .gitignore
  Installed skills (evolve-run, evolve-setup, evolve-status) into .claude/skills and .agents/skills

code-evolve initialized.
```

### Empty fixture

Setup found the engine already installed, left it alone, and drafted an eleven-item checklist.
The cycle built all of it:

```
$ git log --format='%h %s'
96c8574 Day 0 (01:29): session wrap-up
7e4925d Day 0 (01:29): journal entry
fbb95c3 Day 0 (01:29): update proof obligations
ad13649 Day 0 (01:29): scope ruff to project code and apply its formatting
a28dc0b Day 0 (01:29): journal entry
e8ecae5 Day 0 (01:29): update spec progress
528602b Day 0 (01:29): README with install instructions, examples and supported units
36b2665 Day 0 (01:29): command line with formatting, errors, --list, --precision, --help and --version
725020f Day 0 (01:29): project skeleton with length and temperature conversion
ca360f5 code-evolve: initial commit
$ python3 -m unittest discover        # Ran 42 tests ... OK
$ git ls-remote origin
2ad5c438…  refs/tags/day0-01-29          # the tag only: main was not pushed (#132)
```

It hit the same two defects. This agent got past the tooling failure differently: it built a
gitignored `.venv` with pytest and ruff and ran `verify` and `finalize` with it on `PATH`, which a
scheduled cycle would not have ([#133](https://github.com/frankbria/code-evolve/issues/133)).

### Mature fixture

Setup drafted five features: the roadmap, a clear error for a malformed `tasks.json`, and keeping
the docs in step. The cycle built all five:

```
$ git log --format='%h %s'
3f0b017 Day 0 (01:37): session wrap-up
4e5583c Day 0 (01:37): journal entry
75d7578 Day 0 (01:37): update spec progress
a50201d Day 0 (01:37): report a malformed tasks.json without touching it
8b7c9f9 Day 0 (01:37): add list --pending
1c15f59 Day 0 (01:37): add rm command
61fa365 Day 0 (01:37): add done command
6a786c3 tasklite: add and list
$ git ls-remote origin
3f0b0172…  refs/heads/main
7661c4f6…  refs/tags/day0-01-37
$ npm test        # tests 23, pass 23, fail 0
```

### The interactive hand-off

Bare `npx code-evolve` was also started once in a pseudo-terminal on the mature fixture, driven by
a script. This attempt went wrong on the script's side and proves only the hand-off itself:

- The bootstrap asked which agent to use (claude, codex and opencode were all on `PATH`). The
  script typed a sentence meant for a later prompt, which the menu treated as its default, claude.
- It ran `init`, printed `Handing off to claude to finish setup...`, and Claude Code's terminal
  UI opened in the project and showed its folder-trust dialog.
- The script's next line ended with Enter, and that dialog's default is "No, exit", so Claude
  exited. The attempt was not repeated.

What happens after a person accepts the dialog was watched on 2026-11-16 for both agents; see
[below](#interactive-hand-off-both-agents).

## Scheduled run: `code-evolve start --every 1`

A third copy of the mature fixture was installed for a Claude subscription login, onboarded, and
scheduled. No cycle was run by hand.

```bash
npx -y code-evolve@latest init --yes --agent claude --auth-mode oauth
claude -p "/evolve-setup" ...
npx code-evolve start --every 1
```

```
$ npx code-evolve start --every 1          # 01:18 UTC
Saved environment config to .evolve/.env
Cron job installed: every 1 hour
Logs: .evolve/evolve.log

Evolution engine started. The first cycle will run at the next cron interval.
$ crontab -l
0 * * * * cd "<fixture>" && . "<fixture>/.evolve/.env" && EVOLVE_DIR=".evolve" PROJECT_DIR="." AGENT="claude" bash "<fixture>/.evolve/scripts/evolve.sh" >> "<fixture>/.evolve/evolve.log" 2>&1 # code-evolve:<fixture>
```

`.evolve/.env` held `MODEL='claude-sonnet-4-6'`, `AGENT='claude'`, `CLAUDE_AUTH_MODE='oauth'` and
`PATH`, and no API key. Cron fired at 02:00 UTC and the headless cycle ran with nobody attached.
From `.evolve/evolve.log`:

```
=== Day 0 (2026-11-11 02:00) ===
Model: claude-sonnet-4-6
Timeout: 3600s
-> Detecting project stack...
  Stack: javascript
  Test: npm run test
-> Fetching community issues...
  0 issues loaded.
-> Starting evolution session...
[...]
Session finished (41 turns).

-> Session complete. Checking results...
  Build: PASS
[...]
  Committed session wrap-up.
  Tagged: day0-02-00

-> Pushing...
To <remote>/mature-cron.git
   7054aee..bd0938d  main -> main
 * [new tag]         day0-02-00 -> day0-02-00

=== Day 0 complete ===
```

```
$ git log --format='%h %ad %s' --date=format:%H:%M:%S
bd0938d 02:03:30 Day 0 (02:00): session wrap-up
5edb9e2 02:03:22 Day 0 (02:00): journal entry
ac5e435 02:03:14 Day 0 (02:00): update spec progress
803380f 02:03:05 Day 0 (02:00): update README with all commands
07961f2 02:02:55 Day 0 (02:00): clear error on corrupt tasks.json
5a5675b 02:02:44 Day 0 (02:00): add list --pending flag
3cabf6d 02:02:28 Day 0 (02:00): add rm command
05daaef 02:02:07 Day 0 (02:00): add done command
7054aee 01:17:21 tasklite: add and list
$ git ls-remote origin
bd0938dd…  refs/heads/main
460b8570…  refs/tags/day0-02-00
$ npm test        # tests 15, pass 15, fail 0
$ cat .evolve/LAST_VERIFY.md
Day 0 (02:00): verification passed.
$ npx code-evolve stop
Evolution engine stopped. Cron job removed.
$ crontab -l        # (empty)
```

All five spec items were ticked, and the working tree was clean. The cycle finished three and a
half minutes after cron started it.

## Codex (2026-11-08, owner's local date)

These runs were made by the repository owner with codex-cli 0.167 and are recorded in
[#85](https://github.com/frankbria/code-evolve/issues/85); they were not repeated for this
document.

- **First attempt:** setup went through the Codex plugin, with the caveats that became #125, and
  the cycle was reverted. The agent's new test called `spawnSync`, which Codex's sandbox blocks,
  and the test prompt told it to stop on any failure, which cut off the fix-and-reverify loop. The engine reverted the
  session, recorded REQ-0001, committed, tagged and pushed. This became
  [#125](https://github.com/frankbria/code-evolve/issues/125).
- **After #125 was fixed:** on a fresh tasklite fixture,
  `npx code-evolve init --yes --agent codex` in a terminal (Codex's sandbox has no network for
  `npx`), then `$code-evolve:evolve-setup` in `codex exec -s workspace-write`, then
  `$code-evolve:evolve-run` with
  `-c 'sandbox_workspace_write.writable_roots=["<repo>/.git"]'`. The cycle built
  `tasklite done <id>` with tests (7/7 pass), ticked the spec, wrote a journal entry, and
  committed, tagged (`day0-19-27`) and pushed. No shims or workarounds were used.

## Headless `evolve-setup` on Codex (2026-11-14)

For [#156](https://github.com/frankbria/code-evolve/issues/156): does `evolve-setup` recognise a
`codex exec` run as headless and end without a question? On a small Node CLI fixture (one commit,
`npm test` passing), with codex-cli 0.167.2 (`gpt-5.6-sol`, ChatGPT login) and a build of the #156 branch:

```
node dist/cli.js init --yes --agent codex
codex exec -s workspace-write '$evolve-setup' </dev/null
```

The agent's first message said "This is a headless run, so I'll make the recommended choices
without pausing for questions or installing a scheduler", and it checked `ps -o args= -p $PPID`.
It wrote a vision and a seven-item spec, ran `npm test`, installed no schedule, and ended with
what it assumed and the commands for the next steps; no question. OpenCode was not installed on
that machine and was not run.

## Codex matrix and the interactive hand-off (2026-11-16)

These runs cover the rows the earlier runs left open. Everything ran on one machine as the
owner's local user. The setup was WSL2 on Linux 6.18 with Node 24.21 (Node 22.22 for the shell
that started the runs), Python 3.14, codex-cli 0.169.0 (`gpt-5.6-sol`, signed in with ChatGPT)
and Claude Code 2.1.325 (Claude subscription). The build under test was **code-evolve 0.3.1 from
npm** (`npx -y code-evolve@0.3.1`, which includes `init --yes`), so no packed build or substitute
npx cache was needed. The fixtures matched the earlier ones: an empty `git init` repository and
the three-test `tasklite` Node CLI, each under `/tmp` with a local bare repository as `origin`.
For the empty fixtures the idea was the same `uconv` paragraph as above.

Every `codex exec` ran with `--json </dev/null`. Times are wall-clock. Tokens are what Codex
reported: input (most of it cached) and output.

| Session | Time | Tokens in / out |
|---|---|---|
| empty, A: setup, then one answer | 99 s + 86 s | 207k / 4.2k, then a resumed turn |
| empty, A: cycle | 166 s | 1.01M / 6.9k |
| empty, B: setup without `~/.npm` (stopped) / with it | 35 s / 116 s | 95k / 1.0k, 212k / 5.8k |
| empty, B: cycle | 239 s | 1.27M / 10.4k |
| mature, A: setup / cycle | 142 s / 227 s | 332k / 4.9k, 1.35M / 9.6k |

### Codex, empty fixture, path A: `npx code-evolve`

```bash
npx -y code-evolve@0.3.1 init --yes --agent codex          # in a terminal, 1 s
codex exec -s workspace-write --json '$evolve-setup <the idea>' </dev/null
codex exec -s workspace-write -c 'sandbox_workspace_write.writable_roots=["<repo>/.git"]' --json '$evolve-run' </dev/null
```

Setup wrote a vision and a six-item spec, then **ended with three questions** ("You can reply
simply: Accept all; manual."). Nobody can read those in a `codex exec` run. The agent's
headless check, `ps -o args= -p $PPID`, printed `codex-linux-sandbox …` rather than
`codex exec` ([#183](https://github.com/frankbria/code-evolve/issues/183)). A person would type
the answer, so it was given with `codex exec resume <session> "Accept all; manual."`. Setup then
finished in manual mode and installed nothing. Its closing `npx code-evolve status` hung in the
offline sandbox ([#182](https://github.com/frankbria/code-evolve/issues/182)).

The cycle built the first spec item, the package scaffold with a `uconv` entry point, and stopped
there:

```
$ git log --format='%h %s'
db639a3 Day 0 (12:25): session wrap-up
0e18ff2 Day 0 (12:25): satisfy scaffold lint checks
66569ee Day 0 (12:25): journal entry
d1aaa3e Day 0 (12:25): update spec progress
78bbdea Day 0 (12:25): ignore generated Python artifacts
2cbb6e5 Day 0 (12:25): scaffold Python package and CLI entry point
011eb14 code-evolve: initial commit
$ git ls-remote origin
db639a3a…  refs/heads/main
39c11348…  refs/tags/day0-12-25
$ python3 -m unittest discover        # Ran 3 tests ... OK
$ cat .evolve/LAST_VERIFY.md          # Day 0 (12:25): verification passed.
$ git status --short                  # (clean)
```

`main` reached the remote this time, so the #132 fix holds for a repository with no commits.

### Codex, empty fixture, path B: the plugin only

The plugin was installed from this repository's marketplace (`codex plugin marketplace add
<code-evolve checkout>`, `codex plugin add code-evolve@code-evolve`) and removed afterwards. This
time no `init` was run in a terminal: the plugin's setup had to install the engine itself. The
skill says Codex needs `-c sandbox_workspace_write.network_access=true` for that.

```bash
codex exec -s workspace-write -c sandbox_workspace_write.network_access=true \
  --json '$code-evolve:evolve-setup <the idea>' </dev/null
```

With network access alone, `npx -y code-evolve@0.3.1 init` failed with
`EROFS: read-only file system, open '~/.npm/_cacache/tmp/…'`. The sandbox keeps the npm cache
read-only. The agent stopped without changing anything and told the user to run init in a
terminal ([#182](https://github.com/frankbria/code-evolve/issues/182)). The run was repeated
with `~/.npm` writable as well:

```bash
codex exec -s workspace-write -c sandbox_workspace_write.network_access=true \
  -c 'sandbox_workspace_write.writable_roots=["<home>/.npm"]' \
  --json '$code-evolve:evolve-setup <the idea>' </dev/null
codex exec -s workspace-write -c 'sandbox_workspace_write.writable_roots=["<repo>/.git"]' \
  --json '$code-evolve:evolve-run' </dev/null
```

Setup ran init itself, drafted seven features, and finished without a question. `.agents/skills`
was read-only in the sandbox, so the project copies went to `.claude/skills` only; #125 already
records that. The cycle built the whole spec:

```
$ git log --format='%h %s'
0c86182 Day 0 (12:26): session wrap-up
246151f Day 0 (12:26): record verification fixes
abe1a69 Day 0 (12:26): update proof obligations
c7c9759 Day 0 (12:26): satisfy project lint checks
b4a42e7 Day 0 (12:26): auto-format project
94dbcf0 Day 0 (12:26): journal entry
dbdd622 Day 0 (12:26): update spec progress
230d4a2 Day 0 (12:26): ignore generated Python files
1c928a6 Day 0 (12:26): build uconv command-line converter
3a27ab2 code-evolve: initial commit
$ git ls-remote origin
0c861829…  refs/heads/main
7e129583…  refs/tags/day0-12-26
$ python3 -m unittest discover        # Ran 17 tests ... OK
$ cat .evolve/LAST_VERIFY.md          # Day 0 (12:26): verification passed.
$ git status --short                  # (clean)
```

### Codex, mature fixture, path A: from bare `npx code-evolve`

```
$ npx -y code-evolve@0.3.1 < /dev/null
To set up code-evolve, run one of these in your project:

  npx ce init --yes --agent claude && claude /evolve-setup
  npx ce init --yes --agent codex && codex '$evolve-setup'
  npx ce init --yes --agent opencode && opencode --prompt 'Use the evolve-setup skill to set up code-evolve in this project.'
```

**That printout is wrong.** The package has two bins, `code-evolve` and `ce`, and both point at
the same file. When all of a package's bins point at one file, npx runs the first one, and the
registry lists `ce` first. The CLI then names itself after the bin it was started as, so it
printed `npx ce`. But `npx ce` installs an unrelated npm package called `ce`. The PR that added
this section fixes the printout: it always says `npx code-evolve`, and
`tests/test_bootstrap.sh` now runs the CLI as `ce` to check that. `--help` under npx still shows
`Usage: ce`. That is cosmetic and was left alone. The run used the correct command:

```bash
npx -y code-evolve@0.3.1 init --yes --agent codex
codex exec -s workspace-write --json '$evolve-setup' </dev/null
codex exec -s workspace-write -c 'sandbox_workspace_write.writable_roots=["<repo>/.git"]' --json '$evolve-run' </dev/null
```

Setup took its three features from the README roadmap and finished without a question. The cycle
committed the setup files on their own (the #156 fix), then built `tasklite done <id>` with unit
and CLI tests:

```
$ git log --format='%h %s'
410be48 Day 0 (12:34): session wrap-up
5880cc1 Day 0 (12:34): journal entry
651b395 Day 0 (12:34): update spec progress
7c9ade8 Day 0 (12:34): update proof obligations
2570f9e Day 0 (12:34): add task completion command
23d1a4e code-evolve: add the engine and setup files
3191bd8 tasklite: add and list
$ git ls-remote origin
410be48d…  refs/heads/main
678f89de…  refs/tags/day0-12-34
$ npm test        # tests 8, pass 8, fail 0
$ git status --short        # (clean)
```

### Interactive hand-off, both agents

Bare `npx -y code-evolve@0.3.1` was typed into a tmux pane in a fresh `tasklite` fixture, and
every prompt was answered with `tmux send-keys`. The pane's environment was cleared first
(`env -i` with `HOME`, `USER`, `TERM`, `LANG` and a login shell). An earlier attempt started
from inside a `claude -p` session had passed `CLAUDE_CODE_ENTRYPOINT=sdk-cli` down to the
interactive Claude. `evolve-setup` read that variable as headless and asked nothing. That came
from the test harness, not from code-evolve, and the attempt is not counted. Pane captures are
shortened below.

**Claude Code** (claude, codex and opencode were all on `PATH`):

```
$ npx -y code-evolve@0.3.1
Found several agents:
  1. claude
  2. codex
  3. opencode
Which one should set up code-evolve? [1-3] (1): 1
[... init output ...]
code-evolve initialized.
Handing off to claude to finish setup...
 Accessing workspace:
 /tmp/ce85/tty-claude2
 Quick safety check: Is this a project you created or one you trust? [...]
 ❯ No, exit
   Yes, I trust this folder
```

Down and Enter chose "Yes, I trust this folder" for the fixture. The session's transcript starts
with `/evolve-setup`. Setup drafted the vision and spec in the terminal UI, then asked its three
questions as a multiple-choice form:

```
←  ☐ Priorities  ☐ Deps  ☐ Run mode  ✔ Submit  →
│ The spec queues features in the README roadmap order: `done <id>`, then `rm <id>`,
│ then `list --pending`, then input validation and a full usage message. Keep that
│ order?
❯ 1. Keep order (Recommended)
```

The answers were "keep order", "zero dependencies" and "inside a session". The form recommends
"local schedule", which would have installed a cron job on the host. Setup ended with
`code-evolve is set up. Cycles run when you start them from a session, so there's no schedule to
stop.` No permission prompts appeared, because this Claude install runs in auto mode by default.

**Codex** (the same prompt, answered `2`):

```
Handing off to codex to finish setup...
  Folder access
  /tmp/ce85/tty-codex
  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. [...]
› 1. Trust and continue
  2. Back to Agent Command Center
```

Enter chose "Trust and continue". The first prompt in the Codex terminal UI was `› $evolve-setup`.
Setup kept the engine `init` had installed, rewrote the vision and spec, and asked three numbered
questions (accept the drafts, how cycles run, whether to run the first cycle). They were
answered in one typed line: accept, cycles inside agent sessions only, no cycle now. It ended
with `Setup is complete. … Scheduling: none installed; nothing needs stopping.` No approval
prompts appeared: setup ran nothing that needed network or wrote outside the workspace.

Neither interactive pass ran a cycle, because the headless rows above already cover cycles. Both
agents were closed afterwards (`/exit`, `/quit`). The fixture trust entry and the plugin were
removed from Codex's config. No crontab entry was added.

## Codex: `codex exec` and the TUI look the same from inside (2026-11-22)

For [#183](https://github.com/frankbria/code-evolve/issues/183), on codex-cli 0.169.0 (ChatGPT
login). A shell command dumped its environment once under `codex exec -s workspace-write` and once
under the interactive TUI (driven through a pseudo-terminal). The two sets of variable names were
identical, and both had `CODEX_CI=1`, `CODEX_SANDBOX_NETWORK_DISABLED=1`, `TERM=dumb` and no tty.
In both, `ps` showed `codex-linux-sandbox` as PID 1, so nothing above it can be seen. Codex gives
the skill no way to tell the two apart, so `evolve-setup` now keeps the `ps` hint to Claude Code
and OpenCode, and the README's `codex exec` setup command carries the signal in the prompt.

That command, on an empty `git init` repository installed with a build of the #183 branch
(`init --yes --agent codex` in a terminal, so `.agents/skills/` held the changed skill):

```
codex exec -s workspace-write --json '$evolve-setup Build uconv, a small Python command-line tool that converts between units of length, mass and temperature, for people who want quick conversions in a terminal. This run is unattended; nobody will reply.' </dev/null
```

The agent's first message: "Because this run is unattended, I'll make the recommended scope
choices, install no scheduler, and won't start the first evolution cycle." It wrote the vision
and spec, listed its assumptions, installed no schedule, and ended without a question. Its
optional `npx code-evolve status` check hung in the offline sandbox, which is
[#182](https://github.com/frankbria/code-evolve/issues/182).

A Codex run with a writable `/tmp` leaves empty `/tmp/.git`, `/tmp/.agents` and `/tmp/.codex`
directories behind (the sandbox's mount points for paths it keeps read-only). Remove them before
running this repository's tests: `test_session_nudge.sh` creates its non-repository under `/tmp`
and then finds `/tmp/.git`.

## Defects found

| Issue | What |
|---|---|
| [#125](https://github.com/frankbria/code-evolve/issues/125) (closed) | The CLI failed inside Codex's sandbox |
| [#132](https://github.com/frankbria/code-evolve/issues/132) (closed) | A branch with no upstream is not pushed; fresh repositories push only the tag |
| [#133](https://github.com/frankbria/code-evolve/issues/133) (closed) | Python projects fail verification on tooling, and ruff checks the engine's own scripts |
| [#134](https://github.com/frankbria/code-evolve/issues/134) (closed) | Papercuts: npx's PATH saved into the cron `.env`; headless setup ends with questions; setup files swept into the first feature commit |
| fixed with this section | Bare `npx code-evolve` printed `npx ce init …`, which names another npm package |
| [#182](https://github.com/frankbria/code-evolve/issues/182) | Codex plugin-only setup: network access is not enough for npx (read-only `~/.npm`), and the status check hangs offline |
| [#183](https://github.com/frankbria/code-evolve/issues/183) | `evolve-setup` cannot tell `codex exec` from the Codex terminal UI on codex-cli 0.169 |

## What is still open

Nothing is left for [#85](https://github.com/frankbria/code-evolve/issues/85), which covers
Claude Code and Codex (OpenCode is out of its scope). For both agents, every fixture and install
path has a verified, committed first cycle. A cron run passed. Both terminal
UIs ran `evolve-setup`, and those two setup-only rows need no cycle of their own. Follow-ups:

- [#182](https://github.com/frankbria/code-evolve/issues/182) and
  [#183](https://github.com/frankbria/code-evolve/issues/183) (above).
- The `npx ce` printout fix reaches users with the next npm release, since 0.3.1 still prints
  it.
- Optional: a cron run with Codex. The acceptance asks for at least one cron run, and Claude's is
  above.
