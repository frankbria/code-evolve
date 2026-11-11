---
name: evolve-setup
description: Install code-evolve in the current project and onboard it so the codebase can evolve on its own. Drafts the vision and spec from the repo, asks at most five questions, and sets up how cycles run. Use when the user wants to set up, install or onboard code-evolve, or when .evolve/ is missing.
metadata:
  managed-by: code-evolve
---

# Set up code-evolve

Goal: leave the project with code-evolve installed, a real `.evolve/vision.md` and `.evolve/spec.md`,
and a way for cycles to run, while asking the user as little as possible. Do the work yourself and
ask only about what the repository cannot tell you: **at most five questions in the whole setup**,
counting the interview for an empty repository, and not counting yes/no consent for actions.

## 1. Is anyone there to answer?

Decide this first. Nobody can answer (a headless run) when any of these is true:

- You were started by a one-shot command that takes a prompt and exits: `claude -p` (or `--print`),
  `codex exec`, `opencode run`, an SDK call, a CI job or a scheduled task. If you are not sure how
  you were started, `ps -o args= -p $PPID` usually shows the command.
- `echo "$CLAUDE_CODE_ENTRYPOINT"` prints a value that starts with `sdk` (Claude Code sets
  `sdk-cli` under `claude -p`).
- The prompt says the run is unattended, or that no one will reply.

Otherwise someone is there, and the steps below apply as written. When nobody can answer:

- Ask nothing. A question in your last message is never read as a question: the run has ended.
- Step 5: use your recommended answers.
- Step 6: install no schedule, workflow or secret (those need consent). The run mode is
  **inside an agent session, or manually**, which needs nothing installed.
- Step 7: do not run the first cycle unless the prompt asked for one. Do not end with a question
  or with "reply with…" or "tell me which…": state what you assumed and chose, and give the
  command that changes each choice.

## 2. Check the basics

- The project must be a git repository (`git rev-parse --git-dir`). If it is not, offer to run `git init`.
- `npx` must work (`npx --version`). If it does not, tell the user code-evolve needs Node.js 18 or newer.
- Know which agent you are: `claude`, `codex` or `opencode`. Use it for `--agent` below.
- If any code-evolve command fails, stop and tell the user what failed. Never patch, shim, wrap or
  bypass code-evolve or its checks (for example with `NODE_OPTIONS` preloads or edited copies) to get
  past a failure: a faked check leaves a broken install that reports itself as healthy.

## 3. Install the engine

If `.evolve/` does not exist, run:

```bash
npx -y code-evolve@0.2.0 init --yes --agent <your agent>
```

`init --yes` never prompts and is safe to re-run: on an existing install it refreshes the engine
and keeps the user's state and schedule. If `.evolve/` exists but `.evolve/config.json` names a
different agent, run the same command so the install is set for you. The command installs the
version this skill was written for. If init refuses because the installed engine is newer, tell the
user to update the code-evolve plugin (or this skill copy). If npm answers that this version does not exist
(a 404, `ETARGET` or "No matching version"), the release is not published yet: run the command once
more with `code-evolve@latest` and tell the user which version was installed. If `npx` cannot reach npm
(an offline sandbox): with an existing `.evolve/`, say so and continue with it; without one, stop
and tell the user setup needs network access to npm. Codex's default sandbox has no network: ask
the user to start Codex with `-c sandbox_workspace_write.network_access=true` for setup, or to run
`npx code-evolve init --yes --agent codex` in a terminal first. Never edit `config.json` by hand.

init may report a skill directory as `Left alone: ... (not writable here)`: Codex's sandbox makes
`.agents/` read-only. That is fine while the code-evolve plugin is installed (its skills cover it);
mention it, and suggest running init once outside the sandbox to add the project copies.

## 4. Draft the vision and spec

Survey the repository first: README, docs, package manifests, source layout, tests, CI config,
and open issues if `gh` is available.

- **Keep what the user wrote.** A `vision.md` or `spec.md` that no longer has its placeholder
  `<!-- ... -->` comment is the user's: refine it (add what the repo shows is missing, tick
  features that are done) but never discard its priorities, constraints or checkbox progress.
  Draft from scratch only files that are missing or still have the placeholder.
- **Existing codebase:** draft from what is already there. If the repo has a spec-like document
  (PRD, design doc, roadmap) and `.evolve/spec.md` is still the placeholder, convert it with
  `npx code-evolve migrate spec <file> --yes` (or `migrate vision <file> --yes`; both overwrite
  their target) and refine the result.
- **Empty repository:** you need the user's idea. Ask what they want to build and for whom (this
  counts toward the five questions), then draft from the answer.

Write `.evolve/vision.md` (the why and the what: problem, users, what success looks like) and
`.evolve/spec.md` (stack, architecture, testing, and a prioritized feature checklist using
`- [ ]` items). Replace the placeholder `<!-- ... -->` comment in each file: the engine treats a
file that still has it as blank. For an existing codebase, list only features that are not built
yet, and describe the stack the repo already uses.

## 5. Confirm with at most five questions

Show a short summary of both drafts, then ask only what you could not infer, within what is
left of the five questions, each with your recommended answer so the user can just accept. Good questions concern
priorities, scope limits, or things that must never change. Apply the answers to the files.

If nobody can answer (step 1), do not ask: use your recommended answers and list them in the
final summary so the user can revise them later.

## 6. Choose how cycles run

Offer these options and set up the one the user picks (recommend the first for a laptop or
dev box, the second for a team repository). If nobody can answer (step 1), do not offer: cycles
run inside an agent session or manually (the last two options), and nothing is installed.

- **Local schedule:** `npx code-evolve start --every <hours>` installs a cron job. It needs the
  agent's API key in the environment. For a Claude subscription instead, install with
  `npx code-evolve init --yes --agent claude --auth-mode oauth` and log in with `claude auth login`;
  for Codex with a ChatGPT login, use `--agent codex --auth-mode chatgpt` and `codex login`.
- **GitHub Actions:** `npx code-evolve init --yes --mode ci --every <hours>` adds the workflows. The
  repository needs the agent's API key as a secret; offer to run the `gh secret set` command that
  init prints, and run it only with the user's explicit consent.
- **The agent's own scheduler (native):** for users who cannot or will not run cron or Actions.
  See "Native scheduling" below.
- **Inside an agent session:** run the `evolve-run` skill whenever the user wants a cycle.
- **Manually:** `npx code-evolve run` runs one headless cycle.

### Native scheduling

Record the choice with `npx code-evolve init --yes --mode native` (it installs no cron job and no
workflow, and `status` then reports mode `native`). If init says a local schedule is still
installed, run `npx code-evolve stop`; if it says the GitHub Actions schedule is still installed,
offer `gh workflow disable evolve.yml` and run it only with the user's consent. Skip either only
when the user wants both schedulers. Then give the user the prompt for
their scheduler, exactly as written here, and say where it goes. Create the schedule yourself only
if the user explicitly asks you to.

- **Claude Code cloud scheduled task** (formerly "routine"; created at claude.ai/code/routines or
  with `/schedule`, needs a claude.ai subscription login). Prompt:

  ```text
  Run one code-evolve evolution cycle in this repository. Read .claude/skills/evolve-run/SKILL.md and follow it from start to finish. Stay on the default branch: the engine commits, tags and pushes there itself, so do not create a claude/ branch or open a pull request. If the push fails, say so in the first line of your report.
  ```

  Each run is a fresh clone of the default branch, so `.evolve/` and `.claude/skills/` must be
  committed and pushed first. The shortest interval is one hour. Runs count against the user's
  subscription usage, and the push is made as the user's GitHub identity, so a branch protection
  rule that identity cannot bypass blocks it. A cycle that fails to push is lost with the clone.
  Without an authenticated `gh` in the cloud environment, cycles skip community issues.
- **Claude Code Desktop local scheduled task** (the Desktop app's Code tab, Scheduled, with "Only
  on this computer" on and the project as its folder). Prompt:

  ```text
  Run one code-evolve evolution cycle: read .claude/skills/evolve-run/SKILL.md and follow it from start to finish.
  ```

  It runs only while the app is open and the computer is awake, at most hourly from the form.
  Leave "Worktree" off so the cycle lands on the user's branch, and have the user click Run now
  once to approve the permissions a cycle needs, or later runs stall on a prompt.
- **Claude Code `/loop`** (this machine, inside an open session):

  ```text
  /loop 4h Run one code-evolve evolution cycle: read .claude/skills/evolve-run/SKILL.md and follow it from start to finish.
  ```

  It fires only while that session is running and idle, and a recurring loop ends after seven
  days: it suits a burst of cycles, not a standing schedule.
- **Codex scheduled task** (also called an "automation"; created in the ChatGPT desktop app's
  Scheduled view, not in the Codex CLI). Prompt: `$evolve-run`. Choose the local project, not a new
  worktree, so the cycle lands on the branch the user works on. The machine must be on with the app
  running. Tasks run with the user's default sandbox settings, and a cycle needs to write the
  repository's `.git` directory and reach the network to push, so those defaults must allow both.
  In `~/.codex/config.toml`:

  ```toml
  [sandbox_workspace_write]
  writable_roots = ["/absolute/path/to/the/repository/.git"]
  network_access = true
  ```

The Claude prompts name the skill file instead of `/evolve-run` on purpose: `evolve-run` can only be
started by the user, and a scheduled prompt that says `/evolve-run` reaches Claude as plain text.
Prefer one scheduler per repository. Two schedulers working from separate clones both land (the
engine rebases a cycle onto what the remote gained before it pushes), but when both change the same
lines the later cycle is not pushed and ends with exit status 4.

## 7. Finish

Offer to run the first cycle now (the `evolve-run` skill, or `npx code-evolve run`). If nobody can
answer (step 1), name those two ways to run it instead of offering.

For cycles that run on this machine (a local schedule, inside a session, manually) you do not
need to commit what setup installed: the first cycle commits it on its own, before it starts on a
feature, as `code-evolve: add the engine and setup files`. GitHub Actions and a cloud scheduled
task work from the remote, so there the install must be committed and pushed before the first
cycle: offer to do that.

End with a summary: what was installed, the vision and spec in one line each, any answers you
assumed, how cycles will run, and how to stop them for the mode chosen: `npx code-evolve stop`
removes a local schedule; GitHub Actions cycles stop with `gh workflow disable evolve.yml` (or by deleting the
workflow); a native schedule stops where it was made (pause or delete the task at
claude.ai/code/routines or in the ChatGPT app's Scheduled view, or ask Claude to cancel the loop).
`npx code-evolve eject --yes` removes everything.
