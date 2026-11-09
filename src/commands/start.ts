import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import { getEvolveDir, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { cronEntryMarker, getCrontab, setCrontab, withoutProjectEntry } from '../utils/crontab';
import { readConfig, writeConfig, getAgentEnvKey, getAgentEnvHint, isLoginAuth, isValidAgent, resolveModel, savedModelFor, AuthMode } from '../utils/config';
import { codexLoginMissing } from '../utils/checks';


/** Build the "every N hours" cron expression (top of the hour). */
export function hourlyCron(hours: number): string {
  return hours === 1 ? '0 * * * *' : `0 */${hours} * * *`;
}

/** Parse/validate an `--every` hours value. Returns null unless it's a whole
 *  number in 1–24 — a bare integer string only, so "1.5"/"6abc" are rejected
 *  rather than silently truncated by parseInt. */
export function parseInterval(raw: string): number | null {
  if (!/^\d+$/.test(raw.trim())) return null;
  const h = parseInt(raw, 10);
  return h >= 1 && h <= 24 ? h : null;
}

export interface ScheduleOptions {
  agent: string;
  authMode?: AuthMode;
  model: string;
  hours: number;
  projectDir: string;
}

/**
 * Install (or replace) the local cron job for this project and persist
 * schedule.json (display-only metadata read by `status`/`stop` — the cron
 * expression is the only thing that gates run cadence; schedule.json never
 * does). Writes .evolve/.env capturing the current API key (if any).
 * Shared by `code-evolve start` and `code-evolve init --mode local|both`.
 * Throws if the crontab update fails. Does NOT validate env keys — callers
 * decide whether a missing key is fatal.
 */
export function installLocalSchedule(opts: ScheduleOptions): void {
  const { agent, authMode, model, hours, projectDir } = opts;
  const evolveDir = getEvolveDir();
  const envFile = path.join(evolveDir, '.env');
  const logFile = path.join(evolveDir, 'evolve.log');
  const scriptPath = path.join(evolveDir, 'scripts', 'evolve.sh');

  // Ignore .env (and its temporary rewrite file) before any key is written
  ensureEnvGitignored(projectDir);

  // Write .env file for cron (cron doesn't inherit shell env)
  writeEnvFile(envFile, model, agent, authMode);


  // Build cron expression
  const cronSchedule = hourlyCron(hours);

  // The cron command: source .env, run evolve.sh, log output
  const cronCommand = [
    cronSchedule,
    `cd "${projectDir}"`,
    `&& . "${envFile}"`,
    `&& EVOLVE_DIR="${EVOLVE_DIR_NAME}" PROJECT_DIR="." AGENT="${agent}"`,
    `bash "${scriptPath}"`,
    `>> "${logFile}" 2>&1`,
    cronEntryMarker(projectDir),
  ].join(' ');

  // One read and one write: replace this project's entry (if any) and append the new one.
  const { table: existing } = withoutProjectEntry(getCrontab(), projectDir);
  const base = existing && !existing.endsWith('\n') ? `${existing}\n` : existing;
  setCrontab(`${base}${cronCommand}\n`);

  // Save schedule config for `status` display / `stop` cleanup (not a run gate)
  const scheduleConfig = { every: hours, model, agent, authMode: authMode || 'api-key', started: new Date().toISOString() };
  fs.writeFileSync(path.join(evolveDir, 'schedule.json'), JSON.stringify(scheduleConfig, null, 2) + '\n');
}

export const startCommand = new Command('start')
  .description('Start the evolution engine (sets up a recurring local cron job)')
  .option('--every <hours>', 'Run every N hours', '4')
  .option('--model <model>', 'LLM model to use (default depends on agent)')
  .option('--run-now', 'Also run the first evolution cycle immediately')
  .option('--agent <name>', 'Agent backend to use (overrides config)')
  .action(async (options: { every: string; model?: string; runNow?: boolean; agent?: string }) => {
    if (!isInitialized()) {
      console.error('Not initialized. Run `code-evolve init` first.');
      process.exit(1);
    }

    if (process.platform === 'win32') {
      console.error('Local scheduling on native Windows is not supported.');
      console.error('Use WSL, or set up GitHub Actions with: code-evolve init --with-ci');
      process.exit(1);
    }

    // Validate interval
    const hours = parseInterval(options.every);
    if (hours === null) {
      console.error('--every must be an integer between 1 and 24 hours.');
      process.exit(2);
    }

    // Resolve agent
    const config = readConfig();
    const agent = options.agent || config.agent || 'claude';

    if (!isValidAgent(agent)) {
      console.error(`Unknown agent "${agent}". Supported: claude, codex, opencode, ollama`);
      process.exit(1);
    }

    const authMode = config.authMode;
    const envKey = getAgentEnvKey(agent, authMode);

    if (envKey && !process.env[envKey]) {
      console.error(`${envKey} is not set in your environment.`);
      console.error(getAgentEnvHint(agent, authMode));
      process.exit(3);
    }
    if (await codexLoginMissing(agent, authMode)) {
      console.error('Codex is not logged in.');
      console.error(getAgentEnvHint(agent, authMode));
      process.exit(3);
    }

    const model = resolveModel(agent, options.model, config);

    const projectDir = process.cwd();
    const evolveDir = getEvolveDir();
    const scriptPath = path.join(evolveDir, 'scripts', 'evolve.sh');

    // Persist agent choice + mode. `start` always sets up a local schedule, so
    // the mode is at least 'local' (keep 'both' if CI was also chosen).
    // A saved model belongs to the agent it was chosen for, so a switch of agent drops it.
    const savedModel = options.model ? model : savedModelFor(config, agent);
    writeConfig({ ...config, agent, authMode, mode: config.mode === 'both' ? 'both' : 'local', model: savedModel });

    // Install cron entry + write .env + schedule.json
    try {
      installLocalSchedule({ agent, authMode, model, hours, projectDir });
    } catch (err) {
      console.error('Failed to install cron job:', err);
      process.exit(1);
    }

    console.log('Saved environment config to .evolve/.env');
    console.log(`Cron job installed: every ${hours} hour${hours > 1 ? 's' : ''}`);
    console.log(`Logs: .evolve/evolve.log`);

    if (options.runNow) {
      console.log('');
      console.log('Running first evolution cycle...');
      console.log('');
      const { spawn } = require('child_process');
      const child = spawn('bash', [scriptPath], {
        stdio: 'inherit',
        cwd: projectDir,
        env: {
          ...process.env,
          EVOLVE_DIR: EVOLVE_DIR_NAME,
          PROJECT_DIR: '.',
          MODEL: model,
          AGENT: agent,
          ...(authMode === 'oauth' ? { CLAUDE_AUTH_MODE: 'oauth' } : {}),
        },
      });
      child.on('close', (code: number | null) => {
        process.exit(code ?? 1);
      });
    } else {
      console.log('');
      console.log('Evolution engine started. The first cycle will run at the next cron interval.');
      console.log('To run immediately: code-evolve run');
    }
  });

function writeEnvFile(envFile: string, model: string, agent: string, authMode?: AuthMode): void {
  const entries: Array<[string, string | undefined]> = [];

  // Include the relevant API key, except in a login mode (Claude oauth, Codex chatgpt), where the CLI's login is used
  if (!isLoginAuth(agent, authMode)) {
    entries.push(['ANTHROPIC_API_KEY', process.env.ANTHROPIC_API_KEY]);
    entries.push(['OPENAI_API_KEY', process.env.OPENAI_API_KEY]);
  }

  entries.push(['MODEL', model]);
  entries.push(['AGENT', agent]);
  entries.push(['CLAUDE_AUTH_MODE', authMode || 'api-key']);

  // Preserve PATH so cron can find claude, git, python3
  entries.push(['PATH', process.env.PATH]);

  // Cron sources this file with `.`, so each value must be exported (or the engine's
  // child bash never sees it) and single-quoted (so `$`, backticks and `"` stay literal).
  const lines = entries
    .filter((entry): entry is [string, string] => Boolean(entry[1]))
    .map(([name, value]) => `export ${name}='${value.replace(/'/g, `'\\''`)}'`);

  // Write a fresh 0600 file and rename it over .env, so the key is never written into an
  // existing file that has looser permissions (`mode` only applies when a file is created).
  const temporaryFile = `${envFile}.${process.pid}.tmp`;
  fs.rmSync(temporaryFile, { force: true });
  try {
    fs.writeFileSync(temporaryFile, lines.join('\n') + '\n', { mode: 0o600, flag: 'wx' });
    fs.renameSync(temporaryFile, envFile);
  } finally {
    fs.rmSync(temporaryFile, { force: true });
  }
}

function ensureEnvGitignored(projectDir: string): void {
  const gitignorePath = path.join(projectDir, '.gitignore');
  // The wildcard also covers the temporary file writeEnvFile renames into place.
  const entry = `${EVOLVE_DIR_NAME}/.env*`;

  let content = '';
  if (fs.existsSync(gitignorePath)) {
    content = fs.readFileSync(gitignorePath, 'utf8');
  }

  if (!content.includes(entry)) {
    fs.appendFileSync(gitignorePath, `\n${entry}\n`);
  }
}

