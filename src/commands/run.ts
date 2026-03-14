import { Command } from 'commander';
import { spawn } from 'child_process';
import path from 'path';
import { getEvolveDir, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';

export const runCommand = new Command('run')
  .description('Run one evolution cycle')
  .option('--model <model>', 'LLM model to use', 'claude-sonnet-4-6')
  .option('--timeout <seconds>', 'Max session time in seconds', '3600')
  .option('--force', 'Bypass schedule gate')
  .action(async (options: { model: string; timeout: string; force?: boolean }) => {
    if (!isInitialized()) {
      console.error('Not initialized. Run `code-evolve init` first.');
      process.exit(1);
    }

    if (!process.env.ANTHROPIC_API_KEY) {
      console.error('ANTHROPIC_API_KEY is not set.');
      console.error('Export it: export ANTHROPIC_API_KEY=sk-...');
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
