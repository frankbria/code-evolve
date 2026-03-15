import fs from 'fs';
import { evolveFile } from './paths';

export interface EvolveConfig {
  agent: string;
  model?: string;
}

const CONFIG_FILE = 'config.json';
const SUPPORTED_AGENTS = ['claude', 'codex', 'opencode', 'ollama'];

export function getConfigPath(): string {
  return evolveFile(CONFIG_FILE);
}

export function readConfig(): EvolveConfig {
  const configPath = getConfigPath();
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    return JSON.parse(raw);
  } catch {
    return { agent: 'claude' };
  }
}

export function writeConfig(config: EvolveConfig): void {
  const configPath = getConfigPath();
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
}

export function isValidAgent(agent: string): boolean {
  return SUPPORTED_AGENTS.includes(agent);
}

export function getSupportedAgents(): string[] {
  return [...SUPPORTED_AGENTS];
}

const AGENT_ENV_KEYS: Record<string, string> = {
  claude: 'ANTHROPIC_API_KEY',
  codex: 'OPENAI_API_KEY',
  opencode: 'OPENAI_API_KEY',
  ollama: '',
};

export function getAgentEnvKey(agent: string): string {
  return AGENT_ENV_KEYS[agent] || '';
}

export function getAgentEnvHint(agent: string): string {
  switch (agent) {
    case 'claude':
      return 'Set ANTHROPIC_API_KEY environment variable';
    case 'codex':
      return 'Set OPENAI_API_KEY environment variable';
    case 'opencode':
      return 'Set your provider API key (OPENAI_API_KEY or ANTHROPIC_API_KEY)';
    case 'ollama':
      return 'Ensure `ollama serve` is running';
    default:
      return 'Set the appropriate API key for your agent';
  }
}
