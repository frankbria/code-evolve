# Installing code-evolve

This guide covers installing the `code-evolve` CLI, wiring up an AI agent, and
verifying it works. For what the tool does and how the evolution loop runs, see
the [README](README.md).

---

## Prerequisites

| Requirement | Why | Check |
|-------------|-----|-------|
| **Node.js ≥ 18** | Runs the CLI | `node -v` |
| **Git** | The engine commits each cycle | `git --version` |
| **Python 3** | `format_issues.py` sanitizes GitHub issue input | `python3 --version` |
| **An AI coding agent CLI** | Does the actual building (see below) | `claude --version` |
| **An API key** | Auth for your agent (not needed for Ollama, or for Claude in OAuth mode) | — |

### Supported agents

Install **one** of these and make sure its CLI is on your `PATH`:

| Agent | CLI | Install |
|-------|-----|---------|
| Claude Code (default) | `claude` | https://docs.anthropic.com/en/docs/claude-code |
| Codex | `codex` | https://github.com/openai/codex |
| OpenCode | `opencode` | https://github.com/opencode-ai/opencode |
| Ollama (local models) | `ollama` | https://ollama.ai |

---

## Install the CLI

Pick the method that fits how you'll use it.

### Option A — `npx` (no install, recommended to start)

Run it on demand; npm fetches the latest published version each time:

```bash
npx code-evolve init
npx code-evolve setup
```

### Option B — Global install

Installs `code-evolve` and its short alias `ce` on your `PATH`:

```bash
npm install -g code-evolve

code-evolve --version    # or: ce --version
ce init
```

Upgrade later with:

```bash
npm update -g code-evolve
ce init --force          # refresh framework files, preserves journal + learnings
```

### Option C — From source (contributors)

```bash
git clone https://github.com/frankbria/code-evolve.git
cd code-evolve
npm install
npm run build            # compiles TypeScript to dist/
npm link                 # symlinks `code-evolve` and `ce` to this checkout
```

Now `code-evolve` runs your local build. Use `npm run dev` for watch-mode
recompilation while you work. `npm unlink -g code-evolve` removes the symlink.

---

## Set up your agent

### Claude Code

Two auth modes:

- **API key** (default):
  ```bash
  export ANTHROPIC_API_KEY=sk-...
  ```
- **OAuth** (Claude subscription, no API key) — local execution only:
  ```bash
  code-evolve init --auth-mode oauth
  claude login
  ```

### Codex / OpenCode

```bash
export OPENAI_API_KEY=sk-...        # Codex
# OpenCode: set the provider key your OpenCode config expects
code-evolve init --agent codex      # or --agent opencode
```

### Ollama (no API key)

```bash
ollama pull llama3
code-evolve init --agent ollama
```

The chosen `--agent` is saved to `.evolve/config.json`; later `run`/`start`
commands read it automatically.

---

## First run

From inside the project you want to evolve:

```bash
cd your-project

# Guided front door: agent → interview → mode → schedule → ready
code-evolve setup

# …or do it step by step:
code-evolve init           # scaffold .evolve/
code-evolve vision         # interview → .evolve/vision.md
code-evolve spec           # interview → .evolve/spec.md
code-evolve run            # run one cycle manually to verify
code-evolve start          # turn on the scheduler (every 4h by default)
```

Check progress any time:

```bash
code-evolve status
```

---

## Verify the install

```bash
code-evolve --version          # prints the version
code-evolve --help             # lists all 11 commands
code-evolve run                # runs a single evolution cycle end-to-end
```

A successful `run` reads your vision/spec, makes a change, verifies the build,
writes a journal entry (`.evolve/JOURNAL.md`), and commits.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `code-evolve: command not found` after global install | Ensure npm's global bin is on `PATH` (`npm bin -g`); reopen your shell. |
| `npx code-evolve` fetches an old version | `npx code-evolve@latest …` or install globally. |
| Agent CLI not found | Install the agent (see table above) and confirm `claude`/`codex`/`opencode`/`ollama` runs in your shell. |
| Session aborts immediately on a brand-new repo | A repo with **zero commits** currently aborts on start ([#19](https://github.com/frankbria/code-evolve/issues/19)). Make one commit (`git commit --allow-empty -m init`) first. |
| Missing API key | `export ANTHROPIC_API_KEY=…` (or your agent's key), or use Claude `--auth-mode oauth`. |
| Ollama with `--with-ci` | Not supported — Ollama runs models locally and isn't available on hosted CI runners. Use local execution. |

---

## For maintainers — releasing

`package.json` is the single source of the version. `npm version` rewrites the files that repeat it
(both plugin manifests and the install command pinned in the `evolve-setup` skill) through
`scripts/sync-plugin-version.js`; never edit those by hand. CI runs
`node scripts/sync-plugin-version.js --check` and fails on any mismatch.

A release is a pushed `v<version>` tag. The **Release** workflow (`.github/workflows/release.yml`)
then checks the tag against `package.json`, runs the type check and the tests, and, in a second job
that alone holds the publish rights, stages the package on npm with provenance (`npm stage publish`)
and creates the GitHub release with the plugin ZIP
(`code-evolve-plugin-<version>.zip`) attached. A staged version is not installable until a
maintainer approves it with 2FA: on npmjs.com open the package's **Staged Packages** tab, review the
version and choose **Approve**, or run `npm stage approve <stage-id>` (`npm stage list code-evolve`
shows the id). The workflow never runs a direct `npm publish`, so it works with a trusted publisher
that allows staged publishing only. Only `dist/`, `templates/` and `plugins/` are shipped
(see the `files` field in `package.json`).

```bash
npm run lint && npm test         # gate
npm pack --dry-run               # inspect exactly what ships
# move the "Unreleased" notes in CHANGELOG.md under the new version and commit
npm version patch                # or minor / major: bumps every pinned version, commits, tags
git push --follow-tags           # the tag starts the Release workflow
```

Only stable `v<major>.<minor>.<patch>` tags start the workflow; a pre-release tag such as
`v1.3.0-beta.1` does not.

One-time setup on npmjs.com, **before the first tag is pushed**. The version bump reaches `main`
together with the tag, and the plugin served from `main` then installs that exact version, so a
release that cannot publish leaves setup falling back to `@latest` until it is re-run. Either of:

- **Trusted publishing (recommended, no secret):** package settings → Trusted Publisher → GitHub
  Actions, with organization or user `frankbria`, repository `code-evolve`, workflow filename
  `release.yml`, and no environment. Staged publishing (`npm stage publish`) is always allowed;
  direct publishing does not need to be. npm marks a new trusted publisher as unvalidated until its
  first successful publish, and drops it if that does not happen within 2 days, so push the first
  tag soon after saving it. Renaming the workflow file breaks this until the setting is updated.
- **A token:** create a granular access token that can publish `code-evolve` and save it as the
  `NPM_TOKEN` repository secret. The workflow uses it when it is set.

The publish job creates the GitHub release before it stages the version on npm. If the workflow
fails part-way, fix the cause and re-run the job: an existing release only gets the ZIP re-attached,
and a version that is already on npm is not submitted again. npm gives the workflow's trusted-publisher
token no way to see staged versions, so a re-run while the version still waits for approval repairs
the release and then fails at the stage step; approve the staged version on npmjs.com instead.

To test the tarball locally before publishing:

```bash
npm pack                         # produces code-evolve-<version>.tgz
npm install -g ./code-evolve-<version>.tgz
```

### Upload copy for OpenAI's public plugin directory

OpenAI's directory does not take a plugin ZIP that contains lifecycle hooks or app references, so
the release ZIP cannot be uploaded there as it is. Build the upload copy instead:

```bash
scripts/pack-codex-plugin --directory    # dist/code-evolve-plugin-<version>-directory.zip
unzip -l dist/code-evolve-plugin-<version>-directory.zip    # inspect it before the upload
```

It is the committed plugin without `hooks/` and without the `hooks` entry in `plugin.json`; the
skills, icons and listing text are the same. A plugin installed from the directory therefore has no
protected-files hook and no setup reminder at session start. The engine still restores its
protected files after every agent call, and the plugin installed from this repository's marketplace
keeps both hooks. Delete the ZIP from `dist/` afterwards: the npm package ships that directory.

The command names any listing page (`websiteURL`, `supportURL`, `privacyPolicyURL`,
`termsOfServiceURL`) that `plugins/code-evolve/plugin.json` does not have yet. Add each one, as a
published HTTPS page, under `extensions["com.openai"].interface` before building the copy to
upload. Release notes and the countries the plugin is offered in can be set in the same file, under
`extensions["com.openai"].publication` (`release_notes`, `countries`), or in the portal.

The upload itself is manual and needs a verified developer identity: in the plugin submission
portal choose **Upload new or existing plugin**, pick the identity, and upload the ZIP. That creates
a draft. Submitting the draft for review and publishing the approved version are separate steps.
