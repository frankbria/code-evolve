# code-evolve: status

**Updated:** 2026-11-22. Latest npm release: 0.3.1. The previous version of this page (a gap
analysis from June 2026, written for the TTY wizard that has since been retired) is in git history.

## Where it stands

code-evolve is a drop-in, project-level plugin for Claude Code, Codex and any other agent that reads
`SKILL.md` files, built on one vendored engine (epic
[#99](https://github.com/frankbria/code-evolve/issues/99)).

| Area | State | Evidence |
|---|---|---|
| One command (`npx code-evolve`) | Installs `.evolve/` and opens Claude Code, Codex or OpenCode on `evolve-setup` | [first-cycle acceptance](demos/first-cycle-acceptance.md) |
| Claude Code plugin | Marketplace in this repository; `evolve-setup`, `evolve-run`, `evolve-status`; protected-files hook and session-start nudge | same |
| Codex / Agent Plugins plugin | Same skills and hooks through `plugins/code-evolve/plugin.json` | same, Codex sections |
| Any other agent | `npx skills add frankbria/code-evolve` | |
| Onboarding | The `evolve-setup` skill: drafts vision and spec from the repository, at most five questions, headless runs ask nothing | same |
| Engine | `cycle`, plus `prepare` / `verify` / `finalize` for in-session cycles; protected files restored after every agent call; verify and revert; journal; PROOF9 requirements | `npm test` (Jest + shell suite) |
| Schedulers | Local cron, GitHub Actions, the agent's own scheduler (Claude scheduled tasks, `/loop`, Codex scheduled tasks), in-session, manual | cron and Actions runs in the acceptance record; [refused push on Actions](demos/refused-push-on-actions.md) |
| Adapters | claude, codex, opencode, ollama, and any headless CLI through `--agent custom` | adapter tests; live Claude and Codex runs |

Verified live on both Claude Code and Codex: a fresh repository goes from one command to onboarding
to a committed first cycle ([#85](https://github.com/frankbria/code-evolve/issues/85)).

## Known limits

- **Codex's sandbox** keeps `~/.npm` and `.agents/` read-only, has no network by default, and blocks
  synchronous child processes. Setup and cycles work around the first two; the README's Codex notes
  list what to grant.
- **OpenCode** is supported through its adapter and the bootstrap, but its live runs were outside the
  #85 acceptance.
- **Native Windows** is not supported (no cron); use WSL or GitHub Actions.
- **PROOF9** runs automated checks for UNIT, BUILD, LINT and SEC only; the other gates are recorded
  obligations ([PROOF9](PROOF9.md)).

## Open work

See the [open issues](https://github.com/frankbria/code-evolve/issues). At this update:
[#100](https://github.com/frankbria/code-evolve/issues/100) (prepare the Codex plugin for OpenAI's
public plugin directory) and [#8](https://github.com/frankbria/code-evolve/issues/8) (AI video
demos of evolution sessions, future).
