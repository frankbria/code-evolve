import fs from 'fs';
import { evolveFile } from './paths';

export type AuthMode = 'api-key' | 'oauth' | 'chatgpt';

/** Each agent's subscription-login auth mode: the CLI's own login replaces an API key. */
const LOGIN_AUTH_MODES: Record<string, AuthMode> = { claude: 'oauth', codex: 'chatgpt' };

export function isLoginAuth(agent: string, authMode?: AuthMode): boolean {
  return authMode !== undefined && LOGIN_AUTH_MODES[agent] === authMode;
}
/** Where cycles run: local cron, GitHub Actions, both, or `native` (the agent's own scheduler runs the evolve-run skill). */
export type ExecutionMode = 'local' | 'ci' | 'both' | 'native';

export interface EvolveConfig {
  agent: string;
  model?: string;
  authMode?: AuthMode;
  mode?: ExecutionMode;
  /** .gitignore lines init added; eject removes exactly these. */
  gitignoreLinesAdded?: string[];
  /** Files and directories init created outside .evolve/; eject deletes only these (when empty). */
  createdPaths?: string[];
  /** The code-evolve version whose engine files are installed in .evolve/. */
  engineVersion?: string;
  /** agent "custom": the headless command; the prompt goes to stdin, or replaces {prompt_file}. {model} is the model. */
  agentCommand?: string;
  /** agent "custom": an extended regex; a matching log line marks the session failed. */
  agentErrorPattern?: string;
  /** agent "custom": environment variables its CLI needs (credentials); their values reach cron's .env. */
  agentEnvVars?: string[];
}

const CONFIG_FILE = 'config.json';
const SUPPORTED_AGENTS = ['claude', 'codex', 'opencode', 'ollama', 'custom'];
// The interactive picker offers the built-in backends; a custom agent needs --agent-command.
const PICKABLE_AGENTS = SUPPORTED_AGENTS.filter((agent) => agent !== 'custom');
const EXECUTION_MODES: ExecutionMode[] = ['local', 'ci', 'both', 'native'];

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

export function getPickableAgents(): string[] {
  return [...PICKABLE_AGENTS];
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
  if (Number.isInteger(n) && n >= 1 && n <= PICKABLE_AGENTS.length) return PICKABLE_AGENTS[n - 1];
  if (PICKABLE_AGENTS.includes(trimmed)) return trimmed;
  return defaultAgent;
}

const AGENT_ENV_KEYS: Record<string, string> = {
  claude: 'ANTHROPIC_API_KEY',
  codex: 'OPENAI_API_KEY',
  opencode: '',
  ollama: '',
  custom: '',
};

export function getAgentEnvKey(agent: string, authMode?: AuthMode): string {
  if (isLoginAuth(agent, authMode)) return '';
  return AGENT_ENV_KEYS[agent] || '';
}

const AGENT_DEFAULT_MODELS: Record<string, string> = {
  claude: 'claude-sonnet-4-6',
  codex: 'o4-mini',
  // opencode's `run --model` needs a provider-qualified value (see agents/opencode.sh);
  // a bare model name won't resolve.
  opencode: 'anthropic/claude-sonnet-4-6',
  ollama: 'llama3',
  // A custom command picks its own model unless it uses {model} and a model is configured.
  custom: '',
};

export function getDefaultModel(agent: string): string {
  return agent in AGENT_DEFAULT_MODELS ? AGENT_DEFAULT_MODELS[agent] : 'claude-sonnet-4-6';
}

/** The binary a custom agent command runs (its first word), or '' when no command is set. */
export function customCommandBinary(agentCommand?: string): string {
  return agentCommand?.trim().split(/\s+/)[0] ?? '';
}

// Variables a credential must not set: the engine's own (it would override them), and ones that change
// how the cron shell or the tools it starts behave (they would break or hijack every cycle).
const RESERVED_ENV_NAMES = new Set([
  'AGENT', 'MODEL', 'TIMEOUT', 'EVOLVE_DIR', 'PROJECT_DIR', 'REPO', 'FORCE_RUN', 'PATH', 'HOME',
  'CLAUDE_AUTH_MODE', 'AGENT_COMMAND', 'AGENT_ERROR_PATTERN', 'CODE_EVOLVE_MODEL', 'CODE_EVOLVE_PROMPT_FILE',
  'IFS', 'BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS', 'PS4', 'PROMPT_COMMAND', 'CDPATH', 'GLOBIGNORE',
  'LD_PRELOAD', 'LD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES', 'NODE_OPTIONS', 'PYTHONPATH', 'PYTHONSTARTUP',
]);

/** A valid environment variable name that --agent-env may carry (not one the engine sets itself). */
export function isEnvVarName(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && !RESERVED_ENV_NAMES.has(name);
}

/**
 * Engine variables for the custom adapter (agents/custom.sh): the command, the error pattern, and the
 * current values of the credentials it names (agentEnvVars), so scheduled cycles get them too.
 * Empty for the built-in agents.
 */
export function customAgentEnv(agent: string, config: EvolveConfig): Record<string, string> {
  if (agent !== 'custom') return {};
  const credentials = Object.fromEntries(
    (config.agentEnvVars ?? [])
      .filter((name) => isEnvVarName(name) && process.env[name] !== undefined)
      .map((name) => [name, process.env[name] as string]),
  );
  return {
    ...credentials,
    AGENT_COMMAND: config.agentCommand ?? '',
    ...(config.agentErrorPattern ? { AGENT_ERROR_PATTERN: config.agentErrorPattern } : {}),
  };
}

/** The saved model, when it was chosen for `agent`; a model belongs to the agent it was set for. */
export function savedModelFor(config: EvolveConfig, agent: string): string | undefined {
  return config.agent === agent ? config.model : undefined;
}

/** The model a cycle uses: --model, else the configured model (when it was set for this agent), else the agent's default. */
export function resolveModel(agent: string, explicitModel: string | undefined, config: EvolveConfig): string {
  return explicitModel || savedModelFor(config, agent) || getDefaultModel(agent);
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
  if (agent === 'codex' && authMode === 'chatgpt') {
    return 'Log in with `codex login` (ChatGPT subscription auth)';
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
    case 'custom':
      return 'Set whatever your custom command needs (agentCommand in .evolve/config.json)';
    default:
      return 'Set the appropriate API key for your agent';
  }
}
