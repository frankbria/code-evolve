import { Command } from 'commander';
import { WORKFLOW_MARKER, MANAGED_GITIGNORE_LINES, installOperatorSkills, upsertAgentInstructions } from '../utils/projectIntegration';
import { spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import readline from 'readline';
import { getEvolveDir, getTemplatesDir, getOperatorSkillsDir, projectFile, evolveFile, isInitialized, packageVersion, EVOLVE_DIR_NAME } from '../utils/paths';
import { checkDependencies, formatDependencyResults, runProcess } from '../utils/checks';
import {
  readConfig,
  writeConfig,
  isValidAgent,
  getAgentEnvHint,
  getAgentEnvKey,
  getAgentCiProfile,
  getDefaultModel,
  isLoginAuth,
  resolveModel,
  savedModelFor,
  customAgentEnv,
  isEnvVarName,
  getSupportedAgents,
  getPickableAgents,
  resolveAgentSelection,
  resolveModeSelection,
  isValidMode,
  AuthMode,
  ExecutionMode,
  AgentCiProfile,
} from '../utils/config';
import { installLocalSchedule, hourlyCron, parseInterval } from './start';

// Default evolution cadence (hours) when --every isn't passed and isn't chosen interactively.
const DEFAULT_EVERY_HOURS = 4;

// Files that contain user/agent evolution history — never overwrite
const PRESERVE_STATE_FILES = ['JOURNAL.md', 'LEARNINGS.md', 'DAY_COUNT', '.birth_date'];

export interface InitOptions {
  withCi?: boolean;
  force?: boolean;
  agent: string;
  authMode: string;
  mode?: string;
  every?: string;
  yes?: boolean;
  agentCommand?: string;
  agentErrorPattern?: string;
  agentEnv?: string;
}

export const initCommand = new Command('init')
  .description('Initialize .evolve/ in the current project')
  .option('--with-ci', 'Install GitHub Actions workflows')
  .option('--force', 'Overwrite existing .evolve/ directory')
  .option('--agent <name>', 'Agent backend to use (claude, codex, opencode, ollama, custom)', 'claude')
  .option('--agent-command <command>', 'For --agent custom: the headless command (prompt on stdin, or {prompt_file}; {model})')
  .option('--agent-error-pattern <regex>', 'For --agent custom: a log line matching this regex fails the session')
  .option('--agent-env <names>', 'For --agent custom: comma-separated environment variables its CLI needs (saved into the cron .env)')
  .option('--auth-mode <mode>', 'Auth mode: api-key, oauth (Claude login) or chatgpt (Codex login)', 'api-key')
  .option('--mode <mode>', 'Execution mode: local, ci, or both')
  .option('--every <hours>', 'Evolution cadence in hours (1–24)')
  .option('--yes', 'Never prompt; refresh an existing install (managed files only, state kept)')
  .action(runInit);

/**
 * Run the init flow: create `.evolve/`, pick agent/auth/mode/schedule (interactive
 * on a TTY), copy templates, install CI/cron, optionally run the vision+spec
 * interviews, and print next steps. Exported so the `setup` wizard reuses it.
 */
export async function runInit(options: InitOptions): Promise<void> {
    const evolveDir = getEvolveDir();
    const templatesDir = getTemplatesDir();

    // Detect whether flags were explicitly passed (handles both `--agent x` and `--agent=x`)
    const flagPassed = (flag: string): boolean =>
      process.argv.some((a) => a === flag || a.startsWith(`${flag}=`));
    const agentExplicit = flagPassed('--agent');
    const authModeExplicit = flagPassed('--auth-mode');
    const modeExplicit = flagPassed('--mode');
    const everyExplicit = flagPassed('--every');
    const interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY) && !options.yes;
    const wasInitialized = isInitialized();
    const forceExplicit = Boolean(options.force);
    // --yes refreshes an existing install the way --force does, so an agent can re-run it safely.
    if (options.yes) options.force = true;

    // Resolve the evolution cadence: explicit --every wins (validated); else default.
    let hours = DEFAULT_EVERY_HOURS;
    if (everyExplicit) {
      const parsed = parseInterval(options.every ?? '');
      if (parsed === null) {
        console.error('--every must be an integer between 1 and 24 hours.');
        process.exit(2);
      }
      hours = parsed;
    }

    // Resolve agent: explicit flag wins; else existing config on --force; else default.
    const existingConfig = options.force ? readConfig() : { agent: 'claude' };
    let agent = agentExplicit ? options.agent : existingConfig.agent || 'claude';

    // Validate the --auth-mode flag value up front (before any agent-specific rules).
    const isAuthMode = (value: unknown): value is AuthMode => value === 'api-key' || value === 'oauth' || value === 'chatgpt';
    if (!isAuthMode(options.authMode)) {
      console.error(`Unknown auth mode "${options.authMode}". Supported: api-key, oauth (Claude), chatgpt (Codex)`);
      process.exit(1);
    }
    let authMode: AuthMode = options.authMode;
    // On --force, preserve existing authMode if --auth-mode wasn't explicitly passed.
    // readConfig() only guarantees `agent` is a string, so validate the on-disk value
    // before trusting it — a hand-edited config.json must not bypass the check above.
    const existingAuthMode = (existingConfig as { authMode?: unknown }).authMode;
    if (options.force && !authModeExplicit && typeof existingAuthMode === 'string') {
      if (isAuthMode(existingAuthMode)) {
        authMode = existingAuthMode;
      } else {
        console.warn(`Warning: ignoring unsupported auth mode "${existingAuthMode}" from config.json.`);
      }
    }

    // Resolve execution mode: explicit --mode wins; else --with-ci implies 'ci';
    // else preserve existing config.mode on --force; else undefined (decide later).
    let mode: ExecutionMode | undefined;
    if (modeExplicit) {
      if (options.mode && isValidMode(options.mode)) {
        mode = options.mode;
      } else {
        console.error(`Unknown mode "${options.mode}". Supported: local, ci, both`);
        process.exit(1);
      }
    } else if (options.withCi) {
      mode = 'ci';
    } else if (options.force) {
      const existingMode = (existingConfig as { mode?: unknown }).mode;
      if (typeof existingMode === 'string' && isValidMode(existingMode)) mode = existingMode;
    }

    // Fail fast before prompting: don't ask agent/auth questions only to abort.
    if (isInitialized() && !options.force) {
      console.error(`.evolve/ already exists. Use --force to overwrite.`);
      process.exit(1);
    }

    // Interactive picker: on a TTY, when --agent wasn't passed, ask the user.
    if (interactive && !agentExplicit) {
      const picked = await promptForAgentAndAuth(agent, !authModeExplicit);
      agent = picked.agent;
      if (picked.authMode) authMode = picked.authMode;
    }

    // Interactive execution-mode picker: on a TTY, when neither --mode nor
    // --with-ci was passed, ask where evolution should run.
    if (interactive && !modeExplicit && !options.withCi) {
      mode = await promptForMode(mode);
    }

    if (!isValidAgent(agent)) {
      console.error(`Unknown agent "${agent}". Supported: ${getSupportedAgents().join(', ')}`);
      process.exit(1);
    }

    // Each login mode belongs to one agent (oauth: Claude, chatgpt: Codex); fall back for the others.
    if (authMode !== 'api-key' && !isLoginAuth(agent, authMode)) {
      console.warn(`Warning: ${authMode} auth does not apply to the ${agent} agent. Falling back to api-key.`);
      authMode = 'api-key';
    }

    // Check dependencies
    console.log('Checking dependencies...');
    // A custom agent is a command template; keep the saved one unless a new one is passed.
    const agentCommand = agent === 'custom' ? options.agentCommand ?? readConfig().agentCommand : undefined;
    const agentErrorPattern = agent === 'custom' ? options.agentErrorPattern ?? readConfig().agentErrorPattern : undefined;
    const agentEnvVars = agent === 'custom'
      ? options.agentEnv?.split(',').map((name) => name.trim()).filter(Boolean) ?? readConfig().agentEnvVars
      : undefined;
    const invalidEnvName = agentEnvVars?.find((name) => !isEnvVarName(name));
    if (invalidEnvName !== undefined) {
      console.error(`--agent-env: "${invalidEnvName}" is not a valid environment variable name, or is one code-evolve sets itself (MODEL, AGENT, PATH, …).`);
      process.exit(1);
    }
    const unsetEnvNames = (agentEnvVars ?? []).filter((name) => process.env[name] === undefined);
    if (unsetEnvNames.length > 0) {
      console.warn(`  ⚠ --agent-env: ${unsetEnvNames.join(', ')} not set in this shell; scheduled cycles won't get ${unsetEnvNames.length > 1 ? 'them' : 'it'} until you set it and run code-evolve start`);
    }
    if (agent === 'custom' && !agentCommand?.trim()) {
      console.error('--agent custom needs --agent-command "<your CLI> -p ..." (the prompt goes to stdin, or replaces {prompt_file}).');
      process.exit(1);
    }
    // Validate with grep -E itself (exit 2: bad pattern): the adapter matches with it, and JavaScript
    // accepts patterns (lookaheads) that grep -E rejects.
    if (agentErrorPattern !== undefined && (await runProcess('grep', ['-E', '--', agentErrorPattern])).status === 2) {
      console.error(`--agent-error-pattern is not a valid grep -E pattern: ${agentErrorPattern}`);
      process.exit(1);
    }
    const { ok, results } = await checkDependencies(agent, agentCommand);
    console.log(formatDependencyResults(results));

    if (!ok) {
      const missing = results.filter((r) => !r.found).map((r) => r.name);
      console.error(`\nMissing required dependencies: ${missing.join(', ')}`);
      console.error('Install them and try again.');
      process.exit(3);
    }
    console.log('');

    // Create .evolve/ directory structure
    console.log('Creating .evolve/ directory...');
    fs.mkdirSync(path.join(evolveDir, 'scripts'), { recursive: true });
    fs.mkdirSync(path.join(evolveDir, 'skills'), { recursive: true });
    fs.mkdirSync(path.join(evolveDir, 'evidence'), { recursive: true });

    // Copy scripts (always overwrite — these are framework code, not user data)
    copyDir(path.join(templatesDir, 'scripts'), path.join(evolveDir, 'scripts'), evolveDir);

    // Copy skills (always overwrite — framework definitions)
    copyDir(path.join(templatesDir, 'skills'), path.join(evolveDir, 'skills'), evolveDir);

    // The agent's constitution is framework code too (protected from the agent), so it is refreshed.
    const identityPath = path.join(evolveDir, 'IDENTITY.md');
    const shippedIdentity = fs.readFileSync(path.join(templatesDir, 'state', 'IDENTITY.md'));
    if (!writesInside(identityPath, evolveDir)) {
      console.warn('  ⚠ IDENTITY.md is a symlink (a shared constitution?); left alone, so it is not updated');
    } else {
      if (fs.existsSync(identityPath) && !fs.readFileSync(identityPath).equals(shippedIdentity)) {
        console.log('  IDENTITY.md replaced with this version (restore your own copy from git if you customised it)');
      }
      fs.writeFileSync(identityPath, shippedIdentity);
    }

    // Migrate root-level vision.md/spec.md into .evolve/ (0.1.x upgrade path). Only on an explicit
    // --force: under --yes those root files are the project's own documents.
    if (forceExplicit) {
      for (const file of ['vision.md', 'spec.md']) {
        const rootPath = projectFile(file);
        const evolvePath = evolveFile(file);
        if (fs.existsSync(rootPath) && !fs.existsSync(evolvePath)) {
          fs.renameSync(rootPath, evolvePath);
          console.log(`  Moved ${file} → .evolve/${file} (migration from 0.1.x)`);
        } else if (fs.existsSync(rootPath) && fs.existsSync(evolvePath)) {
          console.log(`  Warning: ${file} exists at both root and .evolve/ — using .evolve/ version (root copy is now unused)`);
        }
      }
    }

    // Copy state files (skip if they already exist — these contain evolution history)
    const allStateFiles = ['REQUIREMENTS.md', 'vision.md', 'spec.md', ...PRESERVE_STATE_FILES];
    for (const file of allStateFiles) {
      const src = path.join(templatesDir, 'state', file);
      const dest = path.join(evolveDir, file);
      if (!fs.existsSync(src)) continue;

      if (fs.existsSync(dest)) {
        console.log(`  ${file} already exists — preserving`);
      } else {
        fs.copyFileSync(src, dest);
      }
    }

    // Create .birth_date only if it doesn't exist
    const birthDatePath = path.join(evolveDir, '.birth_date');
    if (!fs.existsSync(birthDatePath)) {
      const today = new Date().toISOString().split('T')[0];
      fs.writeFileSync(birthDatePath, today + '\n');
    }

    // Set executable permissions on scripts
    const scripts = ['evolve.sh', 'detect_stack.sh'];
    for (const script of scripts) {
      const scriptPath = path.join(evolveDir, 'scripts', script);
      if (fs.existsSync(scriptPath)) {
        fs.chmodSync(scriptPath, 0o755);
      }
    }
    // Set executable permissions on agent adapters
    const agentsDir = path.join(evolveDir, 'scripts', 'agents');
    if (fs.existsSync(agentsDir)) {
      for (const file of fs.readdirSync(agentsDir)) {
        if (file.endsWith('.sh')) {
          fs.chmodSync(path.join(agentsDir, file), 0o755);
        }
      }
    }

    // Execution mode drives which artifacts install: CI workflows for ci/both,
    // a local cron job for local/both. --with-ci stays as a back-compat alias.
    const wantCi = mode === 'ci' || mode === 'both' || Boolean(options.withCi);
    const wantLocal = mode === 'local' || mode === 'both';

    // Ask for the cadence interactively only when a schedule will actually be
    // installed and the user didn't already pin it with --every.
    if (interactive && !everyExplicit && (wantCi || wantLocal)) {
      hours = await promptForInterval(hours);
    }

    // Install GitHub Actions workflows directly into .github/workflows/ so they actually run.
    // (GitHub only executes workflows located directly in .github/workflows/, not subdirectories.)
    // Renamed to evolve-* so they never clobber a target repo's own ci.yml/evolve.yml.
    // The evolve workflow is templated for the configured agent (CLI install, secret,
    // AGENT/MODEL). Ollama has no CI profile — it needs local model compute — so its
    // install is skipped rather than scheduling a workflow that times out every cycle.
    // Our workflows stay managed after a switch to local mode (`start` leaves them in place), so a
    // refresh updates any that exist even when it would not install them.
    const ourWorkflowsInstalled = ['evolve.yml', 'evolve-ci.yml'].some((name) => {
      const file = projectFile(path.join('.github', 'workflows', name));
      return fs.existsSync(file) && fs.readFileSync(file, 'utf8').includes(WORKFLOW_MARKER);
    });
    const ciProfile = wantCi || ourWorkflowsInstalled ? getAgentCiProfile(agent) : null;
    if (wantCi && !ciProfile) {
      console.warn(
        `  ⚠ Skipping GitHub Actions install: "${agent}" runs models locally and isn't supported on hosted CI runners. Use local execution (code-evolve start) for "${agent}".`
      );
      // Don't persist a CI mode we just refused to install — local is the only
      // viable mode for this backend, so reflect that in config.json/status.
      if (mode === 'ci' || mode === 'both') {
        mode = 'local';
      }
    } else if (ciProfile) {
      console.log(wantCi ? 'Installing GitHub Actions workflows...' : 'Refreshing installed GitHub Actions workflows...');
      const workflowDir = projectFile('.github/workflows');
      fs.mkdirSync(workflowDir, { recursive: true });
      const workflowMap: Record<string, string> = {
        'evolve.yml': 'evolve.yml',
        'ci.yml': 'evolve-ci.yml',
      };
      for (const [src, destName] of Object.entries(workflowMap)) {
        const srcPath = path.join(templatesDir, 'workflows', src);
        const destPath = path.join(workflowDir, destName);
        if (!fs.existsSync(srcPath)) continue;
        const installed = fs.existsSync(destPath) ? fs.readFileSync(destPath, 'utf8') : null;
        const ours = installed !== null && installed.includes(WORKFLOW_MARKER);
        if (installed === null && !wantCi) continue;
        if (!writesInside(destPath, process.cwd())) {
          console.warn(`  ⚠ ${path.relative(process.cwd(), destPath)} is a symlink or under one leading outside the project; left alone, so it is not updated`);
          continue;
        }
        if (installed !== null && !ours) {
          // A same-named file already exists — leave it untouched, but make clear our
          // workflow was NOT installed so the user knows evolution/CI won't run from it.
          console.warn(
            `  ⚠ ${path.relative(process.cwd(), destPath)} already exists — skipping; code-evolve's ${destName} was NOT installed (rename or remove the existing file to install it)`
          );
        } else {
          // Template the cadence + agent into the evolve workflow before writing, so
          // --every and the chosen backend reach CI. (evolve-ci.yml has nothing to template.)
          if (src === 'evolve.yml') {
            // A non-interactive refresh keeps the cadence already in our workflow; --every or an
            // interval chosen at the prompt replaces it (the same rule as the local schedule).
            const installedEvery = Number(installed?.match(/# every (\d+)/)?.[1]);
            const workflowHours = !everyExplicit && !interactive && ours && installedEvery > 0 ? installedEvery : hours;
            const templated = templateEvolveWorkflow(fs.readFileSync(srcPath, 'utf8'), agent, workflowHours, ciProfile);
            fs.writeFileSync(destPath, templated);
          } else {
            fs.copyFileSync(srcPath, destPath);
          }
          console.log(`  ${ours ? 'Updated' : 'Created'} ${path.relative(process.cwd(), destPath)}`);
        }
      }
      console.log(`  CI secret: ${ciProfile.secretHint}`);
    }

    // Update .gitignore before scheduling (which also touches it), remembering exactly what was
    // added so eject can remove only that
    const currentConfig = readConfig();
    const gitignoreChange = updateGitignore();
    const gitignoreLinesAdded = [...(currentConfig.gitignoreLinesAdded ?? []), ...gitignoreChange.added];

    // Install the local cron schedule for local/both modes. Native Windows has
    // no cron, so skip with a pointer to CI. We only install when the agent's
    // API key is already in the environment (or none is needed); otherwise the
    // cron .env would be written without it — defer to `code-evolve start` once
    // the key is set, matching init's "set your key as a next step" model.
    let localScheduled = false;
    // A refresh keeps the user's schedule (cadence, model) unless they asked to change it.
    const previousConfig = readConfig();
    const agentChanged = agent !== previousConfig.agent;
    const authChanged = authMode !== (previousConfig.authMode ?? 'api-key');
    // A custom agent's command and pattern live in the cron .env, so changing either reinstalls it.
    const customCommandChanged = agent === 'custom'
      && (agentCommand !== previousConfig.agentCommand || agentErrorPattern !== previousConfig.agentErrorPattern
        || (agentEnvVars ?? []).join(',') !== (previousConfig.agentEnvVars ?? []).join(','));
    const keepSchedule = wasInitialized && !interactive && !modeExplicit && !everyExplicit
      && !agentChanged && !authChanged && !customCommandChanged && fs.existsSync(evolveFile('schedule.json'));
    // Reinstalling for a changed agent, auth or custom command keeps the cadence the user already chose.
    if (wasInitialized && !everyExplicit && !interactive) {
      const previousEvery = readScheduleEvery();
      if (previousEvery !== null) hours = previousEvery;
    }
    // `stop` removes schedule.json but keeps the mode, so a plain refresh of a stopped engine
    // (no --mode/--every, not interactive) must not quietly start unattended cycles again.
    const engineStopped = wasInitialized && !interactive && !modeExplicit && !everyExplicit
      && !fs.existsSync(evolveFile('schedule.json'));
    if (keepSchedule && wantLocal) {
      console.log('  Keeping the existing local schedule');
    } else if (wantLocal && engineStopped) {
      console.log('  Local schedule is stopped; leaving it stopped (resume with: code-evolve start)');
    } else if (wantLocal) {
      if (process.platform === 'win32') {
        console.warn('  ⚠ Local scheduling is not supported on native Windows — use WSL or ci mode.');
      } else {
        const envKey = getAgentEnvKey(agent, authMode);
        if (!envKey || process.env[envKey]) {
          try {
            installLocalSchedule({
              agent, authMode, model: resolveModel(agent, undefined, previousConfig), hours, projectDir: process.cwd(),
              // The config is written after scheduling, so pass this run's custom command directly.
              agentEnv: customAgentEnv(agent, { agent, agentCommand, agentErrorPattern, agentEnvVars }),
            });
            console.log(`Local schedule installed: every ${hours}h (.evolve/evolve.log)`);
            localScheduled = true;
          } catch (err) {
            console.warn(`  ⚠ Could not install local cron job: ${(err as Error).message}`);
          }
        } else {
          console.warn(`  ⚠ Local schedule not installed yet: ${envKey} is not set. Set it, then run \`code-evolve start\`.`);
        }
      }
    }


    // Operator skills where agents discover them, plus a short note for any agent working here.
    const skills = installOperatorSkills(process.cwd(), getOperatorSkillsDir());
    const createdInstructionFiles = upsertAgentInstructions(process.cwd());
    const createdPaths = [...new Set([
      ...(currentConfig.createdPaths ?? []),
      ...(gitignoreChange.created ? ['.gitignore'] : []),
      ...skills.createdDirs,
      ...createdInstructionFiles,
    ])];
    if (skills.installedDirs.length > 0) {
      console.log(`  Installed skills (${skills.installed.join(', ')}) into ${skills.installedDirs.join(' and ')}`);
    }
    for (const skipped of skills.skipped) console.warn(`  ⚠ Left alone: ${skipped}`);

    // Write agent config (persist execution mode when one was chosen)
    writeConfig({
      ...currentConfig,
      agent,
      authMode,
      ...(mode ? { mode } : {}),
      gitignoreLinesAdded,
      createdPaths,
      engineVersion: packageVersion(),
      ...(agent === 'custom' ? { agentCommand, agentErrorPattern, agentEnvVars } : {}),
      // A saved model belongs to the agent it was chosen for, so a switch of agent drops it.
      model: savedModelFor(currentConfig, agent),
    });
    if (agent !== 'claude') {
      console.log(`  Agent: ${agent}`);
    }
    if (authMode === 'oauth') {
      console.log(`  Auth: OAuth (claude login)`);
    }
    if (authMode === 'chatgpt') {
      console.log(`  Auth: ChatGPT login (codex login); CI still uses OPENAI_API_KEY`);
    }
    if (mode) {
      console.log(`  Mode: ${mode}`);
    }

    console.log('');
    console.log('code-evolve initialized.');
    console.log('');

    // On a TTY, offer to run the vision + spec interviews right now so onboarding
    // flows straight into artifact generation. Declining (or non-TTY) falls through
    // to the manual "edit these files" guidance below — scripted/CI installs are
    // never prompted. We only drop the manual step for a file the interview
    // actually populated, so a cancelled interview still gets its "edit" reminder.
    let visionDone = false;
    let specDone = false;
    if (interactive) {
      const launch = await promptYesNo('Generate your vision + spec now via a guided interview? (yes/no): ');
      if (launch) {
        visionDone = runInterview('vision');
        specDone = runInterview('spec');
        console.log('');
      }
    }

    console.log('Next steps:');
    let step = 1;
    if (!visionDone) {
      console.log(`  ${step++}. Edit .evolve/vision.md with your project vision`);
    }
    if (!specDone) {
      console.log(`  ${step++}. Edit .evolve/spec.md with your technical specification`);
    }
    console.log(`  ${step++}. ${getAgentEnvHint(agent, authMode)}`);
    if (localScheduled) {
      console.log(`  ${step++}. Local evolution runs every ${hours}h. Run now: code-evolve run`);
    } else {
      console.log(`  ${step++}. Run: code-evolve run`);
    }
    if (!wantCi || !wantLocal) {
      console.log('');
      console.log('  To choose where evolution runs (local / ci / both):');
      console.log('    code-evolve init --mode <local|ci|both> --force');
    }
}

/** Ask a yes/no question on the current TTY. Defaults to no on empty/EOF. */
async function promptYesNo(question: string): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = await new Promise<string>((resolve) => {
      // EOF (Ctrl-D / closed TTY) fires 'close' without ever calling the
      // question callback — resolve empty so we follow the declined path.
      rl.on('close', () => resolve(''));
      rl.question(question, resolve);
    });
    const normalized = answer.trim().toLowerCase();
    return normalized === 'y' || normalized === 'yes';
  } finally {
    rl.close();
  }
}

/**
 * Launch one of the interview subcommands (`vision`/`spec`) by re-invoking this
 * same CLI as a child process with inherited stdio, so it owns the terminal
 * cleanly. Returns true only if the interview actually populated the target file
 * (the user can cancel mid-interview and exit 0), so callers know whether the
 * manual "edit this file" guidance is still needed.
 */
function runInterview(name: 'vision' | 'spec'): boolean {
  const file = evolveFile(`${name}.md`);
  const read = (): string => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '');
  const before = read();
  const res = spawnSync(process.execPath, [process.argv[1], name], { stdio: 'inherit' });
  if (res.status !== 0) {
    console.warn(`  (${name} interview did not complete — run \`code-evolve ${name}\` anytime.)`);
  }
  const after = read();
  return after.trim() !== '' && after !== before;
}

/**
 * Template the bundled evolve.yml for the configured agent: the cron cadence, the
 * AGENT/MODEL job env, the CLI install step, and the secret env block (between the
 * `# code-evolve:secrets` markers). For the Claude default these replacements are
 * no-ops, so the workflow round-trips unchanged.
 */
function templateEvolveWorkflow(
  src: string,
  agent: string,
  hours: number,
  profile: AgentCiProfile,
): string {
  return src
    .replace(/-\s*cron:\s*'[^']*'[^\n]*/, `- cron: '${hourlyCron(hours)}'  # every ${hours}h`)
    .replace(/^( *AGENT: ).*$/m, `$1${agent}`)
    .replace(/^( *MODEL: ).*$/m, `$1${getDefaultModel(agent)}`)
    .replace('npm install -g @anthropic-ai/claude-code', profile.cliInstall)
    // The secret block is repeated on each agent run step — replace every occurrence.
    .replace(
      /^ *# code-evolve:secrets[\s\S]*?# code-evolve:secrets-end\n/gm,
      profile.envBlock,
    );
}

/** Copy directory recursively, overwriting all files (for framework code). */
/** Copy `src` into `dest`, never writing through a symlink that leads outside `root`. */
function copyDir(src: string, dest: string, root: string): void {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath, root);
    } else if (!writesInside(destPath, root)) {
      console.warn(`  ⚠ ${path.relative(process.cwd(), destPath)} is a symlink or under one leading outside ${path.relative(process.cwd(), root) || 'the project'}; left alone, so it is not updated`);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

/**
 * Interactively prompt for the agent backend (and, for Claude, the auth mode)
 * using Node's built-in readline. Returns `authMode` only when it was asked.
 */
async function promptForAgentAndAuth(
  defaultAgent: string,
  askAuth: boolean,
): Promise<{ agent: string; authMode?: AuthMode }> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = (q: string): Promise<string> => new Promise((resolve) => rl.question(q, resolve));
  try {
    const agents = getPickableAgents();
    console.log('Which agent backend should drive evolution?');
    agents.forEach((a, i) => console.log(`  ${i + 1}. ${a}${a === defaultAgent ? ' (default)' : ''}`));
    // A saved custom agent is not in the menu, so Enter keeps it; say so instead of showing a number.
    const defaultLabel = agents.includes(defaultAgent) ? String(agents.indexOf(defaultAgent) + 1) : `keep ${defaultAgent}`;
    const defaultIdx = agents.indexOf(defaultAgent) + 1;
    const raw = await ask(`Select [1-${agents.length}] (default ${defaultLabel}): `);
    const agent = resolveAgentSelection(raw, defaultAgent);
    if (raw.trim() && agent === defaultAgent && raw.trim() !== defaultAgent && raw.trim() !== String(defaultIdx)) {
      console.log(`  Unrecognized choice — using ${defaultAgent}.`);
    }

    if (agent === 'claude' && askAuth) {
      console.log('Claude auth mode:');
      console.log('  1. api-key — ANTHROPIC_API_KEY (default)');
      console.log('  2. oauth — claude login / subscription');
      const a = (await ask('Select [1-2] (default 1): ')).trim().toLowerCase();
      return { agent, authMode: a === '2' || a === 'oauth' ? 'oauth' : 'api-key' };
    }
    return { agent };
  } finally {
    rl.close();
  }
}

/**
 * Interactively ask where evolution should run. Free-text (local/ci/both/skip)
 * to avoid colliding with the numbered agent picker's "Select [1-N]" prompt.
 * Empty / "skip" keeps the current `fallback` (decide later).
 */
async function promptForMode(fallback: ExecutionMode | undefined): Promise<ExecutionMode | undefined> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    console.log('Where should evolution run?');
    console.log('  local — schedule a cron job on this machine');
    console.log('  ci    — install GitHub Actions workflows');
    console.log('  both  — local + CI');
    console.log('  skip  — decide later (default)');
    const raw = await new Promise<string>((resolve) => {
      rl.on('close', () => resolve(''));
      rl.question('Select [local/ci/both/skip] (default skip): ', resolve);
    });
    return resolveModeSelection(raw) ?? fallback;
  } finally {
    rl.close();
  }
}

/**
 * Ask how often evolution should run (hours). Empty/invalid input keeps the
 * current `fallback`. Free-text to match the other init prompts' style.
 */
async function promptForInterval(fallback: number): Promise<number> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const raw = await new Promise<string>((resolve) => {
      rl.on('close', () => resolve(''));
      rl.question(`How often should evolution run, in hours? [1-24] (default ${fallback}): `, resolve);
    });
    if (!raw.trim()) return fallback;
    const parsed = parseInterval(raw);
    if (parsed === null) {
      console.log(`  Invalid interval — using ${fallback}h.`);
      return fallback;
    }
    return parsed;
  } finally {
    rl.close();
  }
}

/** The cadence of the installed local schedule, or null when there is none (or it is unreadable). */
/**
 * False when `file` is a symlink, or a symlinked directory below `root` would land the write outside
 * where `root` really lives: git could neither show nor restore what the refresh overwrote there.
 * `root` itself may be a symlink (a symlinked .evolve, which the engine supports).
 */
function writesInside(file: string, root: string): boolean {
  // A symlinked managed file is left alone even inside the project: it may point at a user-owned file.
  if (fs.lstatSync(file, { throwIfNoEntry: false })?.isSymbolicLink()) return false;
  let existing = file;
  while (!fs.existsSync(existing) && path.dirname(existing) !== existing) existing = path.dirname(existing);
  const target = fs.realpathSync(existing);
  const realRoot = fs.realpathSync(root);
  return target === realRoot || target.startsWith(realRoot + path.sep);
}

function readScheduleEvery(): number | null {
  try {
    const schedule: unknown = JSON.parse(fs.readFileSync(evolveFile('schedule.json'), 'utf8'));
    if (typeof schedule === 'object' && schedule !== null && 'every' in schedule && typeof schedule.every === 'number') {
      return schedule.every;
    }
    return null;
  } catch {
    return null;
  }
}

function updateGitignore(): { added: string[]; created: boolean } {
  const gitignorePath = projectFile('.gitignore');
  const created = !fs.existsSync(gitignorePath);
  const content = created ? '' : fs.readFileSync(gitignorePath, 'utf8');
  const existing = new Set(content.split('\n'));
  const added = MANAGED_GITIGNORE_LINES.filter((line) => !existing.has(line));
  if (added.length === 0) return { added, created: false };
  const separator = content === '' || content.endsWith('\n') ? '' : '\n';
  fs.writeFileSync(gitignorePath, `${content}${separator}${added.join('\n')}\n`);
  console.log('  Updated .gitignore');
  return { added, created };
}
