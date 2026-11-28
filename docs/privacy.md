# code-evolve privacy policy

Effective on publication. Last updated 27 November 2026.

This policy covers code-evolve: the `code-evolve` npm package, the code-evolve plugin for Claude Code,
Codex and other agents, its skills, and the engine it installs in your repository. code-evolve is
published by Noatak Enterprises, LLC.

## What we collect

Nothing. code-evolve has no accounts, telemetry, analytics or crash reporting, and it sends nothing
to any code-evolve or Noatak Enterprises service. There is no such service.

## What code-evolve does on your machine

code-evolve runs local shell scripts, Python helpers and git in your own repository. It writes its
files there (the `.evolve/` folder, skills folders, a section in `AGENTS.md` or `CLAUDE.md`,
`.gitignore` lines and, if you choose them, GitHub Actions workflows or a cron job), and each cycle
commits its changes to your repository. The plugin's hooks run locally and read only files in your
repository and in the plugin.

## Other services

code-evolve itself runs no service. It works through tools you install and sign in to, and each
service below handles your data under its own terms and privacy policy:

- **Your AI agent.** The agent you choose (Claude Code, Codex, OpenCode, Ollama or a custom command)
  reads your repository and the prompts code-evolve gives it, as it does when you use it directly.
  Those prompts point it at your vision, spec and journal and, when `gh` is available, include the
  text of your repository's open issues and excerpts of failed CI logs. What the agent's provider receives and keeps is
  governed by the provider's terms and privacy policy.
- **Your git remote.** Cycles fetch from and push commits and tags to the remote your repository
  already uses.
- **GitHub, through your `gh` CLI.** If `gh` is installed and signed in, cycles read your repository's
  issues and CI results and comment on or close the issues they work on. If you set
  `ENABLE_SPONSORS=true`, they also read your own GitHub Sponsors list.
- **npm.** Installing or upgrading with `npx` downloads the package from the npm registry.
- **The web.** When it researches something unfamiliar, the cycle agent may send search queries of
  its own choosing to DuckDuckGo and download public web pages.
- **GitHub Actions.** In GitHub Actions mode, cycles run in your own GitHub account with the secrets
  you store there.

## Contact

Questions about this policy: open an issue at
[github.com/frankbria/code-evolve/issues](https://github.com/frankbria/code-evolve/issues).

## Changes

Changes to this policy are published on this page with a new "Last updated" date.
