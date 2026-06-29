import { Command } from 'commander';
import { spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import readline from 'readline';
import { getEvolveDir, getTemplatesDir, projectFile, evolveFile, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { checkDependencies, formatDependencyResults } from '../utils/checks';
import {
  readConfig,
  writeConfig,
  isValidAgent,
  getAgentEnvHint,
  getAgentEnvKey,
  getDefaultModel,
  getSupportedAgents,
  resolveAgentSelection,
  resolveModeSelection,
  isValidMode,
  AuthMode,
  ExecutionMode,
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
}

export const initCommand = new Command('init')
  .description('Initialize .evolve/ in the current project')
  .option('--with-ci', 'Install GitHub Actions workflows')
  .option('--force', 'Overwrite existing .evolve/ directory')
  .option('--agent <name>', 'Agent backend to use (claude, codex, opencode, ollama)', 'claude')
  .option('--auth-mode <mode>', 'Auth mode for Claude: api-key or oauth', 'api-key')
  .option('--mode <mode>', 'Execution mode: local, ci, or both')
  .option('--every <hours>', 'Evolution cadence in hours (1–24)')
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
    const interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY);

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
    let authMode: AuthMode;
    if (options.authMode === 'oauth') {
      authMode = 'oauth';
    } else if (options.authMode === 'api-key') {
      authMode = 'api-key';
    } else {
      console.error(`Unknown auth mode "${options.authMode}". Supported: api-key, oauth`);
      process.exit(1);
    }
    // On --force, preserve existing authMode if --auth-mode wasn't explicitly passed.
    // readConfig() only guarantees `agent` is a string, so validate the on-disk value
    // before trusting it — a hand-edited config.json must not bypass the check above.
    const existingAuthMode = (existingConfig as { authMode?: unknown }).authMode;
    if (options.force && !authModeExplicit && typeof existingAuthMode === 'string') {
      if (existingAuthMode === 'api-key' || existingAuthMode === 'oauth') {
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

    // oauth only applies to Claude — fall back for other backends.
    if (authMode === 'oauth' && agent !== 'claude') {
      console.warn(`Warning: oauth auth is only applicable to the Claude agent. Falling back to api-key.`);
      authMode = 'api-key';
    }

    // Check dependencies
    console.log('Checking dependencies...');
    const { ok, results } = checkDependencies(agent);
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
    copyDir(path.join(templatesDir, 'scripts'), path.join(evolveDir, 'scripts'));

    // Copy skills (always overwrite — framework definitions)
    copyDir(path.join(templatesDir, 'skills'), path.join(evolveDir, 'skills'));

    // Migrate root-level vision.md/spec.md into .evolve/ (0.1.x upgrade path)
    if (options.force) {
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
    const allStateFiles = ['IDENTITY.md', 'REQUIREMENTS.md', 'vision.md', 'spec.md', ...PRESERVE_STATE_FILES];
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
    // The bundled CI workflow is Claude-only today (installs claude-code, uses
    // ANTHROPIC_API_KEY). Skip the install for other backends rather than schedule a
    // workflow that would run the wrong agent / fail every cycle. Tracked for per-agent CI.
    if (wantCi && agent !== 'claude') {
      console.warn(
        `  ⚠ Skipping GitHub Actions install: the bundled workflow supports the Claude backend only and would run the wrong agent in CI. Use local execution (code-evolve start) for "${agent}". Per-agent CI is tracked as a follow-up.`
      );
    } else if (wantCi) {
      console.log('Installing GitHub Actions workflows...');
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
        if (fs.existsSync(destPath)) {
          // A same-named file already exists — leave it untouched, but make clear our
          // workflow was NOT installed so the user knows evolution/CI won't run from it.
          console.warn(
            `  ⚠ ${path.relative(process.cwd(), destPath)} already exists — skipping; code-evolve's ${destName} was NOT installed (rename or remove the existing file to install it)`
          );
        } else {
          // Template the cadence into the evolve workflow's schedule before writing,
          // so --every reaches CI too (the other workflow has no cron to template).
          if (src === 'evolve.yml') {
            const templated = fs
              .readFileSync(srcPath, 'utf8')
              .replace(/-\s*cron:\s*'[^']*'[^\n]*/, `- cron: '${hourlyCron(hours)}'  # every ${hours}h`);
            fs.writeFileSync(destPath, templated);
          } else {
            fs.copyFileSync(srcPath, destPath);
          }
          console.log(`  Created ${path.relative(process.cwd(), destPath)}`);
        }
      }
    }

    // Install the local cron schedule for local/both modes. Native Windows has
    // no cron, so skip with a pointer to CI. We only install when the agent's
    // API key is already in the environment (or none is needed); otherwise the
    // cron .env would be written without it — defer to `code-evolve start` once
    // the key is set, matching init's "set your key as a next step" model.
    let localScheduled = false;
    if (wantLocal) {
      if (process.platform === 'win32') {
        console.warn('  ⚠ Local scheduling is not supported on native Windows — use WSL or ci mode.');
      } else {
        const envKey = getAgentEnvKey(agent, authMode);
        if (!envKey || process.env[envKey]) {
          try {
            installLocalSchedule({ agent, authMode, model: getDefaultModel(agent), hours, projectDir: process.cwd() });
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

    // Update .gitignore (appends only if marker not already present)
    updateGitignore();

    // Write agent config (persist execution mode when one was chosen)
    const currentConfig = readConfig();
    writeConfig({ ...currentConfig, agent, authMode, ...(mode ? { mode } : {}) });
    if (agent !== 'claude') {
      console.log(`  Agent: ${agent}`);
    }
    if (authMode === 'oauth') {
      console.log(`  Auth: OAuth (claude login)`);
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

/** Copy directory recursively, overwriting all files (for framework code). */
function copyDir(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
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
    const agents = getSupportedAgents();
    console.log('Which agent backend should drive evolution?');
    agents.forEach((a, i) => console.log(`  ${i + 1}. ${a}${a === defaultAgent ? ' (default)' : ''}`));
    const defaultIdx = Math.max(agents.indexOf(defaultAgent), 0) + 1;
    const raw = await ask(`Select [1-${agents.length}] (default ${defaultIdx}): `);
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

function updateGitignore(): void {
  const gitignorePath = projectFile('.gitignore');
  const linesToAdd = [
    `# code-evolve ephemeral files`,
    `${EVOLVE_DIR_NAME}/ISSUES_TODAY.md`,
    `${EVOLVE_DIR_NAME}/ISSUE_RESPONSE.md`,
    `${EVOLVE_DIR_NAME}/.env`,
    `${EVOLVE_DIR_NAME}/evolve.log`,
    `${EVOLVE_DIR_NAME}/schedule.json`,
    `${EVOLVE_DIR_NAME}/evidence/`,
  ];

  let content = '';
  if (fs.existsSync(gitignorePath)) {
    content = fs.readFileSync(gitignorePath, 'utf8');
  }

  // Check if already added
  if (content.includes(`${EVOLVE_DIR_NAME}/ISSUES_TODAY.md`)) {
    return;
  }

  const addition = '\n' + linesToAdd.join('\n') + '\n';
  fs.appendFileSync(gitignorePath, addition);
  console.log('  Updated .gitignore');
}
