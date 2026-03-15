import { Command } from 'commander';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { getEvolveDir, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { readConfig, writeConfig, getAgentEnvKey, getAgentEnvHint, isValidAgent } from '../utils/config';

const CRON_MARKER = 'code-evolve';

export const startCommand = new Command('start')
  .description('Start the evolution engine (sets up a recurring local cron job)')
  .option('--every <hours>', 'Run every N hours', '4')
  .option('--model <model>', 'LLM model to use', 'claude-sonnet-4-6')
  .option('--run-now', 'Also run the first evolution cycle immediately')
  .option('--agent <name>', 'Agent backend to use (overrides config)')
  .action(async (options: { every: string; model: string; runNow?: boolean; agent?: string }) => {
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
    const hours = parseInt(options.every, 10);
    if (isNaN(hours) || hours < 1 || hours > 24) {
      console.error('--every must be between 1 and 24 hours.');
      process.exit(2);
    }

    // Resolve agent
    const config = readConfig();
    const agent = options.agent || config.agent || 'claude';

    if (!isValidAgent(agent)) {
      console.error(`Unknown agent "${agent}". Supported: claude, codex, opencode, ollama`);
      process.exit(1);
    }

    const envKey = getAgentEnvKey(agent);

    if (envKey && !process.env[envKey]) {
      console.error(`${envKey} is not set in your environment.`);
      console.error(getAgentEnvHint(agent));
      process.exit(3);
    }

    // Persist agent choice
    writeConfig({ ...config, agent });

    const projectDir = process.cwd();
    const evolveDir = getEvolveDir();
    const envFile = path.join(evolveDir, '.env');
    const logFile = path.join(evolveDir, 'evolve.log');
    const scriptPath = path.join(evolveDir, 'scripts', 'evolve.sh');

    // Write .env file for cron (cron doesn't inherit shell env)
    writeEnvFile(envFile, options.model, agent);
    console.log('Saved API key to .evolve/.env');

    // Ensure .evolve/.env is gitignored
    ensureEnvGitignored(projectDir);

    // Remove any existing code-evolve cron entry for this project
    removeExistingCron(projectDir);

    // Build cron expression
    const cronSchedule = hours === 1 ? '0 * * * *' : `0 */${hours} * * *`;

    // The cron command: source .env, run evolve.sh, log output
    const cronCommand = [
      cronSchedule,
      `cd "${projectDir}"`,
      `&& . "${envFile}"`,
      `&& EVOLVE_DIR="${EVOLVE_DIR_NAME}" PROJECT_DIR="." AGENT="${agent}"`,
      `bash "${scriptPath}"`,
      `>> "${logFile}" 2>&1`,
      `# ${CRON_MARKER}:${projectDir}`,
    ].join(' ');

    // Install cron entry
    try {
      const existing = getCrontab();
      const updated = existing ? existing + '\n' + cronCommand + '\n' : cronCommand + '\n';
      setCrontab(updated);
    } catch (err) {
      console.error('Failed to install cron job:', err);
      process.exit(1);
    }

    console.log(`Cron job installed: every ${hours} hour${hours > 1 ? 's' : ''}`);
    console.log(`Logs: .evolve/evolve.log`);

    // Save schedule config for status command
    const scheduleConfig = { every: hours, model: options.model, agent, started: new Date().toISOString() };
    fs.writeFileSync(path.join(evolveDir, 'schedule.json'), JSON.stringify(scheduleConfig, null, 2) + '\n');

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
          MODEL: options.model,
          AGENT: agent,
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

function writeEnvFile(envFile: string, model: string, agent: string): void {
  const lines: string[] = [];

  // Include the relevant API key
  if (process.env.ANTHROPIC_API_KEY) {
    lines.push(`ANTHROPIC_API_KEY="${process.env.ANTHROPIC_API_KEY}"`);
  }
  if (process.env.OPENAI_API_KEY) {
    lines.push(`OPENAI_API_KEY="${process.env.OPENAI_API_KEY}"`);
  }

  lines.push(`MODEL="${model}"`);
  lines.push(`AGENT="${agent}"`);

  // Preserve PATH so cron can find claude, git, python3
  if (process.env.PATH) {
    lines.push(`PATH="${process.env.PATH}"`);
  }

  fs.writeFileSync(envFile, lines.join('\n') + '\n', { mode: 0o600 });
}

function ensureEnvGitignored(projectDir: string): void {
  const gitignorePath = path.join(projectDir, '.gitignore');
  const entry = `${EVOLVE_DIR_NAME}/.env`;

  let content = '';
  if (fs.existsSync(gitignorePath)) {
    content = fs.readFileSync(gitignorePath, 'utf8');
  }

  if (!content.includes(entry)) {
    fs.appendFileSync(gitignorePath, `\n${entry}\n`);
  }
}

function getCrontab(): string {
  try {
    return execSync('crontab -l 2>/dev/null', { encoding: 'utf8' });
  } catch {
    return '';
  }
}

function setCrontab(content: string): void {
  execSync(`echo ${JSON.stringify(content)} | crontab -`, { encoding: 'utf8' });
}

function removeExistingCron(projectDir: string): void {
  const existing = getCrontab();
  if (!existing) return;

  const marker = `${CRON_MARKER}:${projectDir}`;
  const lines = existing.split('\n').filter((line) => !line.includes(marker));
  const cleaned = lines.join('\n').replace(/\n{3,}/g, '\n\n');
  setCrontab(cleaned);
}
