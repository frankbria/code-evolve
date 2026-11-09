import { Command } from 'commander';
import { spawn } from 'child_process';
import path from 'path';
import { getEvolveDir, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { readConfig, getAgentEnvKey, getAgentEnvHint, getSupportedAgents, isValidAgent, resolveModel, customAgentEnv, customCommandBinary } from '../utils/config';
import { codexLoginMissing, isOnPath } from '../utils/checks';

export const runCommand = new Command('run')
  .description('Run one evolution cycle')
  .option('--model <model>', 'LLM model to use (default depends on agent)')
  .option('--timeout <seconds>', 'Max session time in seconds', '3600')
  .option('--force', 'Bypass sponsor bonus-run gate')
  .option('--agent <name>', 'Agent backend to use (overrides config)')
  .action(async (options: { model?: string; timeout: string; force?: boolean; agent?: string }) => {
    if (!isInitialized()) {
      console.error('Not initialized. Run `code-evolve init` first.');
      process.exit(1);
    }

    const config = readConfig();
    const agent = options.agent || config.agent || 'claude';

    if (!isValidAgent(agent)) {
      console.error(`Unknown agent "${agent}". Supported: ${getSupportedAgents().join(', ')}`);
      process.exit(1);
    }

    const model = resolveModel(agent, options.model, config);
    const authMode = config.authMode;
    const envKey = getAgentEnvKey(agent, authMode);

    if (envKey && !process.env[envKey]) {
      console.error(`${envKey} is not set.`);
      console.error(getAgentEnvHint(agent, authMode));
      process.exit(3);
    }
    if (agent === 'custom' && !isOnPath(customCommandBinary(config.agentCommand))) {
      console.error(config.agentCommand
        ? `The custom agent command's binary (${customCommandBinary(config.agentCommand)}) is not on PATH.`
        : 'AGENT=custom needs agentCommand in .evolve/config.json (code-evolve init --agent custom --agent-command "...").');
      process.exit(3);
    }
    if (await codexLoginMissing(agent, authMode)) {
      console.error('Codex is not logged in.');
      console.error(getAgentEnvHint(agent, authMode));
      process.exit(3);
    }

    const evolveDir = getEvolveDir();
    const scriptPath = path.join(evolveDir, 'scripts', 'evolve.sh');

    const env = {
      ...process.env,
      EVOLVE_DIR: EVOLVE_DIR_NAME,
      PROJECT_DIR: '.',
      MODEL: model,
      TIMEOUT: options.timeout,
      AGENT: agent,
      ...customAgentEnv(agent, config),
      ...(options.force ? { FORCE_RUN: 'true' } : {}),
      ...(authMode === 'oauth' ? { CLAUDE_AUTH_MODE: 'oauth' } : {}),
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
