import fs from 'fs';
import { evolveFile } from './paths';

export type AuthMode = 'api-key' | 'oauth';
export type ExecutionMode = 'local' | 'ci' | 'both';

export interface EvolveConfig {
  agent: string;
  model?: string;
  authMode?: AuthMode;
  mode?: ExecutionMode;
}

const CONFIG_FILE = 'config.json';
const SUPPORTED_AGENTS = ['claude', 'codex', 'opencode', 'ollama'];
const EXECUTION_MODES: ExecutionMode[] = ['local', 'ci', 'both'];

export function getConfigPath(): string {
  return evolveFile(CONFIG_FILE);
}

export function readConfig(): EvolveConfig {
  const configPath = getConfigPath();
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const parsed = JSON.parse(raw);
    if (typeof parsed === 'object' && parsed !== null && typeof parsed.agent === 'string') {
      return parsed as EvolveConfig;
    }
    return { agent: 'claude' };
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

export function isValidMode(mode: string): mode is ExecutionMode {
  return (EXECUTION_MODES as string[]).includes(mode);
}

export function getExecutionModes(): ExecutionMode[] {
  return [...EXECUTION_MODES];
}

/**
 * Resolve an interactive execution-mode answer. Accepts a 1-based list index
 * ("2"), a mode name ("ci"), or "skip"/empty (returns undefined — decide later).
 */
export function resolveModeSelection(raw: string): ExecutionMode | undefined {
  const trimmed = raw.trim().toLowerCase();
  if (!trimmed || trimmed === 'skip' || trimmed === 'none') return undefined;
  const n = Number(trimmed);
  if (Number.isInteger(n) && n >= 1 && n <= EXECUTION_MODES.length) return EXECUTION_MODES[n - 1];
  if (isValidMode(trimmed)) return trimmed;
  return undefined;
}

export function getSupportedAgents(): string[] {
  return [...SUPPORTED_AGENTS];
}

/**
 * Resolve an interactive agent picker answer to an agent name.
 * Accepts a 1-based list index ("2") or an agent name ("codex").
 * Empty or unrecognized input falls back to `defaultAgent`.
 */
export function resolveAgentSelection(raw: string, defaultAgent: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return defaultAgent;
  const n = Number(trimmed);
  if (Number.isInteger(n) && n >= 1 && n <= SUPPORTED_AGENTS.length) return SUPPORTED_AGENTS[n - 1];
  if (SUPPORTED_AGENTS.includes(trimmed)) return trimmed;
  return defaultAgent;
}

const AGENT_ENV_KEYS: Record<string, string> = {
  claude: 'ANTHROPIC_API_KEY',
  codex: 'OPENAI_API_KEY',
  opencode: '',
  ollama: '',
};

export function getAgentEnvKey(agent: string, authMode?: AuthMode): string {
  if (agent === 'claude' && authMode === 'oauth') return '';
  return AGENT_ENV_KEYS[agent] || '';
}

const AGENT_DEFAULT_MODELS: Record<string, string> = {
  claude: 'claude-sonnet-4-6',
  codex: 'o4-mini',
  opencode: 'claude-sonnet-4-6',
  ollama: 'llama3',
};

export function getDefaultModel(agent: string): string {
  return AGENT_DEFAULT_MODELS[agent] || 'claude-sonnet-4-6';
}

export function getAgentEnvHint(agent: string, authMode?: AuthMode): string {
  if (agent === 'claude' && authMode === 'oauth') {
    return 'Ensure you are logged in via `claude login` (OAuth/subscription auth)';
  }
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
