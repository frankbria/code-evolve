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
  // opencode's `run --model` needs a provider-qualified value (see agents/opencode.sh);
  // a bare model name won't resolve.
  opencode: 'anthropic/claude-sonnet-4-6',
  ollama: 'llama3',
};

export function getDefaultModel(agent: string): string {
  return AGENT_DEFAULT_MODELS[agent] || 'claude-sonnet-4-6';
}

/**
 * CI-templating profile for a backend: how the bundled GitHub Actions workflow
 * installs the CLI and which secret it wires. Returns `null` for agents that
 * can't run on hosted runners (ollama needs local model compute), signalling
 * init to skip the CI install rather than schedule a workflow that times out.
 */
export interface AgentCiProfile {
  /** Shell command for the workflow's "Install agent CLI" step. */
  cliInstall: string;
  /** YAML lines (6-space indented, with markers) for the job-level secret env. */
  envBlock: string;
  /** Post-install hint, e.g. the `gh secret set` command for the backend. */
  secretHint: string;
}

/**
 * Build the templated secret env block placed on each agent run step (between the
 * workflow's `# code-evolve:secrets` markers). Step-level `env:` is indented 10
 * spaces — keeping secrets off the job scope so third-party setup actions never see them.
 */
function secretEnvBlock(lines: string[]): string {
  const indent = '          ';
  const body = lines.map((l) => `${indent}${l}`).join('\n');
  return `${indent}# code-evolve:secrets — agent backend secrets (templated by init)\n${body}\n${indent}# code-evolve:secrets-end\n`;
}

export function getAgentCiProfile(agent: string): AgentCiProfile | null {
  switch (agent) {
    case 'claude':
      // CI is always api-key (OAuth is local-only), regardless of local authMode.
      return {
        cliInstall: 'npm install -g @anthropic-ai/claude-code',
        envBlock: secretEnvBlock([
          'ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}',
          'CLAUDE_AUTH_MODE: api-key',
        ]),
        secretHint: 'gh secret set ANTHROPIC_API_KEY',
      };
    case 'codex':
      return {
        cliInstall: 'npm install -g @openai/codex',
        envBlock: secretEnvBlock(['OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}']),
        secretHint: 'gh secret set OPENAI_API_KEY',
      };
    case 'opencode':
      // Provider-dependent: ship both keys so either configured provider works.
      return {
        cliInstall: 'npm install -g opencode-ai',
        envBlock: secretEnvBlock([
          'OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}',
          'ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}',
        ]),
        // Default opencode model is Anthropic-provider, so lead with that secret.
        secretHint: 'gh secret set ANTHROPIC_API_KEY   # or OPENAI_API_KEY, per your opencode provider/model',
      };
    case 'ollama':
    default:
      return null; // local-only — not viable on hosted CI runners
  }
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
