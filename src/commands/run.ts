import { Command } from 'commander';
import { spawn } from 'child_process';
import path from 'path';
import { getEvolveDir, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { readConfig, getAgentEnvKey, getAgentEnvHint, isValidAgent } from '../utils/config';

export const runCommand = new Command('run')
  .description('Run one evolution cycle')
  .option('--model <model>', 'LLM model to use', 'claude-sonnet-4-6')
  .option('--timeout <seconds>', 'Max session time in seconds', '3600')
  .option('--force', 'Bypass schedule gate')
  .option('--agent <name>', 'Agent backend to use (overrides config)')
  .action(async (options: { model: string; timeout: string; force?: boolean; agent?: string }) => {
    if (!isInitialized()) {
      console.error('Not initialized. Run `code-evolve init` first.');
      process.exit(1);
    }

    const config = readConfig();
    const agent = options.agent || config.agent || 'claude';

    if (!isValidAgent(agent)) {
      console.error(`Unknown agent "${agent}". Supported: claude, codex, opencode, ollama`);
      process.exit(1);
    }

    const envKey = getAgentEnvKey(agent);

    if (envKey && !process.env[envKey]) {
      console.error(`${envKey} is not set.`);
      console.error(getAgentEnvHint(agent));
      process.exit(3);
    }

    const evolveDir = getEvolveDir();
    const scriptPath = path.join(evolveDir, 'scripts', 'evolve.sh');

    const env = {
      ...process.env,
      EVOLVE_DIR: EVOLVE_DIR_NAME,
      PROJECT_DIR: '.',
      MODEL: options.model,
      TIMEOUT: options.timeout,
      AGENT: agent,
      ...(options.force ? { FORCE_RUN: 'true' } : {}),
    };

    const child = spawn('bash', [scriptPath], {
      stdio: 'inherit',
      cwd: process.cwd(),
      env,
    });

    child.on('close', (code) => {
      process.exit(code ?? 1);
    });
  });
