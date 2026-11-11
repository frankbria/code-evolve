# Acceptance demo: fresh repo → one command → first evolution cycle

This is the live record for [#85](https://github.com/frankbria/code-evolve/issues/85), the
end-to-end proof for the cross-agent plugin epic ([#99](https://github.com/frankbria/code-evolve/issues/99)).
Every command below was run against real agents; nothing here is inferred from the test suite.
Long outputs are shortened to the lines that matter.

**Where it stands (2026-11-11):** on Claude Code, both fixtures went from install to a verified,
committed first cycle through both install paths, and a cron-triggered cycle committed and pushed
on its own. Those sessions were headless (`claude -p`): the `npx code-evolve` path was run as the
commands the bootstrap prints, not through Claude's terminal UI. On Codex, the plugin route passed
on one fixture on 2026-11-08. Still open: the rest of the Codex matrix, and one pass through each
agent's interactive terminal UI (see [What is still open](#what-is-still-open)).

| Agent | Fixture | Install path | Setup | First cycle | Result |
|---|---|---|---|---|---|
| Claude Code | mature | B: plugin | drafted 4 features | 7 commits, 13/13 tests | passed, tag and branch pushed |
| Claude Code | empty | B: plugin | drafted 10 features | 10 commits, 41/41 tests | passed, but only the tag was pushed ([#132](https://github.com/frankbria/code-evolve/issues/132)) |
| Claude Code | empty | A: `npx code-evolve`, headless | drafted 11 features | 10 commits, 42/42 tests | passed, but only the tag was pushed ([#132](https://github.com/frankbria/code-evolve/issues/132)) |
| Claude Code | mature | A: `npx code-evolve`, headless | drafted 5 features | 7 commits, 23/23 tests | passed, tag and branch pushed |
| Claude Code | mature | cron, `start --every 1` | drafted 5 features | 8 commits, 15/15 tests | passed unattended at 02:00 UTC, tag and branch pushed |
| Codex | mature | B: plugin, after `init` in a terminal | done | `tasklite done <id>`, 7/7 tests | passed on 2026-11-08, tag and branch pushed |
| Codex | empty | A and B | | | not run |
| Codex | mature | A: `npx code-evolve` | | | not run |

"Passed" means the engine's own `verify` passed, `finalize` committed and tagged the session, the
working tree was clean afterwards, and the project's test suite passes when run by hand.

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

What happens after a person accepts the dialog (the `/evolve-setup` prompt running inside the
terminal UI) has not been watched for either agent.

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

## Defects found

| Issue | What |
|---|---|
| [#125](https://github.com/frankbria/code-evolve/issues/125) (closed) | The CLI failed inside Codex's sandbox |
| [#132](https://github.com/frankbria/code-evolve/issues/132) | A branch with no upstream is not pushed; fresh repositories push only the tag |
| [#133](https://github.com/frankbria/code-evolve/issues/133) | Python projects fail verification on tooling, and ruff checks the engine's own scripts |
| [#134](https://github.com/frankbria/code-evolve/issues/134) | Papercuts: npx's PATH saved into the cron `.env`; headless setup ends with questions; setup files swept into the first feature commit |

## What is still open

For [#85](https://github.com/frankbria/code-evolve/issues/85) to close:

1. **Codex on the empty fixture**, through both install paths, and **Codex through
   `npx code-evolve`** on the mature fixture. Codex needs its owner's login.
2. **One interactive pass per agent:** type `npx code-evolve` in a terminal, accept the agent's
   prompts, and confirm `evolve-setup` runs in its terminal UI. With npm still serving the old
   0.2.0, this needs a local build or the next release ([#95](https://github.com/frankbria/code-evolve/issues/95)).
3. Optionally a cron run with Codex; the acceptance asks for at least one cron run, and Claude's
   is above.
