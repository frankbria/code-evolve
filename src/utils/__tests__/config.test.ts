import fs from 'fs';
import os from 'os';
import path from 'path';
import {
  isValidAgent,
  isValidMode,
  getExecutionModes,
  getSupportedAgents,
  resolveModeSelection,
  resolveAgentSelection,
  getAgentEnvKey,
  getDefaultModel,
  getAgentEnvHint,
  getAgentCiProfile,
  readConfig,
  writeConfig,
  isLoginAuth,
  resolveModel,
  customAgentEnv,
  customCommandBinary,
  isEnvVarName,
} from '../config';

describe('agent validation', () => {
  it('accepts every supported agent and rejects unknowns', () => {
    for (const a of getSupportedAgents()) expect(isValidAgent(a)).toBe(true);
    expect(isValidAgent('gpt')).toBe(false);
    expect(isValidAgent('')).toBe(false);
  });
});

describe('execution-mode validation', () => {
  it('accepts the three modes and rejects others', () => {
    expect(getExecutionModes()).toEqual(['local', 'ci', 'both', 'native']);
    for (const m of getExecutionModes()) expect(isValidMode(m)).toBe(true);
    expect(isValidMode('cloud')).toBe(false);
  });
});

describe('resolveModeSelection', () => {
  it('maps 1-based index, name, and skip/empty', () => {
    expect(resolveModeSelection('1')).toBe('local');
    expect(resolveModeSelection('2')).toBe('ci');
    expect(resolveModeSelection('3')).toBe('both');
    expect(resolveModeSelection('4')).toBe('native');
    expect(resolveModeSelection('ci')).toBe('ci');
    expect(resolveModeSelection('Native')).toBe('native');
    expect(resolveModeSelection('BOTH')).toBe('both');
    expect(resolveModeSelection('')).toBeUndefined();
    expect(resolveModeSelection('skip')).toBeUndefined();
    expect(resolveModeSelection('9')).toBeUndefined();
    expect(resolveModeSelection('bogus')).toBeUndefined();
  });
});

describe('resolveAgentSelection', () => {
  it('maps index and name, falling back to the default', () => {
    expect(resolveAgentSelection('1', 'claude')).toBe('claude');
    expect(resolveAgentSelection('2', 'claude')).toBe('codex');
    expect(resolveAgentSelection('opencode', 'claude')).toBe('opencode');
    expect(resolveAgentSelection('', 'codex')).toBe('codex');
    expect(resolveAgentSelection('99', 'claude')).toBe('claude');
    expect(resolveAgentSelection('nope', 'ollama')).toBe('ollama');
  });
});

describe('getAgentEnvKey', () => {
  it('returns the provider key, gating Claude OAuth to none', () => {
    expect(getAgentEnvKey('claude')).toBe('ANTHROPIC_API_KEY');
    expect(getAgentEnvKey('claude', 'api-key')).toBe('ANTHROPIC_API_KEY');
    expect(getAgentEnvKey('claude', 'oauth')).toBe('');
    expect(getAgentEnvKey('codex')).toBe('OPENAI_API_KEY');
    expect(getAgentEnvKey('opencode')).toBe('');
    expect(getAgentEnvKey('ollama')).toBe('');
    expect(getAgentEnvKey('unknown')).toBe('');
  });
});

describe('getDefaultModel', () => {
  it('returns a per-agent default; opencode is provider-qualified', () => {
    expect(getDefaultModel('claude')).toBe('claude-sonnet-4-6');
    expect(getDefaultModel('codex')).toBe('o4-mini');
    // opencode `run --model` needs provider/model — a bare name won't resolve.
    expect(getDefaultModel('opencode')).toBe('anthropic/claude-sonnet-4-6');
    expect(getDefaultModel('ollama')).toBe('llama3');
    expect(getDefaultModel('unknown')).toBe('claude-sonnet-4-6');
  });
});

describe('getAgentEnvHint', () => {
  it('describes the credential for each backend', () => {
    expect(getAgentEnvHint('claude')).toMatch(/ANTHROPIC_API_KEY/);
    expect(getAgentEnvHint('claude', 'oauth')).toMatch(/claude login/);
    expect(getAgentEnvHint('codex')).toMatch(/OPENAI_API_KEY/);
    expect(getAgentEnvHint('ollama')).toMatch(/ollama serve/);
  });
});

describe('getAgentCiProfile', () => {
  it('builds a CI profile for hosted-runner backends', () => {
    const claude = getAgentCiProfile('claude')!;
    expect(claude.cliInstall).toContain('@anthropic-ai/claude-code');
    expect(claude.envBlock).toContain('ANTHROPIC_API_KEY');
    expect(claude.envBlock).toContain('# code-evolve:secrets');
    expect(claude.secretHint).toContain('ANTHROPIC_API_KEY');

    const codex = getAgentCiProfile('codex')!;
    expect(codex.cliInstall).toContain('@openai/codex');
    expect(codex.envBlock).toContain('OPENAI_API_KEY');
    expect(codex.envBlock).not.toContain('ANTHROPIC_API_KEY');

    const opencode = getAgentCiProfile('opencode')!;
    expect(opencode.cliInstall).toContain('opencode-ai');
    // Default opencode model is Anthropic-provider, so the hint leads with it.
    expect(opencode.secretHint).toContain('ANTHROPIC_API_KEY');
  });

  it('returns null for local-only / unknown agents', () => {
    expect(getAgentCiProfile('ollama')).toBeNull();
    expect(getAgentCiProfile('unknown')).toBeNull();
  });

  it('indents the secret env block at step scope (10 spaces)', () => {
    const block = getAgentCiProfile('codex')!.envBlock;
    for (const line of block.split('\n').filter(Boolean)) {
      expect(line.startsWith('          ')).toBe(true);
    }
  });
});

describe('readConfig / writeConfig round-trip', () => {
  let tmp: string;
  let cwd: string;

  beforeEach(() => {
    cwd = process.cwd();
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'evolve-cfg-'));
    fs.mkdirSync(path.join(tmp, '.evolve'));
    process.chdir(tmp);
  });

  afterEach(() => {
    process.chdir(cwd);
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it('persists and reads back a config', () => {
    writeConfig({ agent: 'codex', authMode: 'api-key', mode: 'ci' });
    expect(readConfig()).toEqual({ agent: 'codex', authMode: 'api-key', mode: 'ci' });
  });

  it('defaults to claude when the file is missing or malformed', () => {
    expect(readConfig()).toEqual({ agent: 'claude' });
    fs.writeFileSync(path.join(tmp, '.evolve', 'config.json'), '{ not json');
    expect(readConfig()).toEqual({ agent: 'claude' });
    // An object without a string `agent` is rejected too.
    fs.writeFileSync(path.join(tmp, '.evolve', 'config.json'), JSON.stringify({ mode: 'ci' }));
    expect(readConfig()).toEqual({ agent: 'claude' });
  });
});

describe('subscription-login auth per agent', () => {
  it('maps each login mode to its own agent only', () => {
    expect(isLoginAuth('claude', 'oauth')).toBe(true);
    expect(isLoginAuth('codex', 'chatgpt')).toBe(true);
    expect(isLoginAuth('codex', 'oauth')).toBe(false);
    expect(isLoginAuth('claude', 'chatgpt')).toBe(false);
    expect(isLoginAuth('codex', 'api-key')).toBe(false);
    expect(isLoginAuth('codex', undefined)).toBe(false);
  });

  it('needs no API key in a login mode, and says how to log in', () => {
    expect(getAgentEnvKey('codex', 'chatgpt')).toBe('');
    expect(getAgentEnvKey('codex', 'api-key')).toBe('OPENAI_API_KEY');
    expect(getAgentEnvKey('codex', 'oauth')).toBe('OPENAI_API_KEY');
    expect(getAgentEnvHint('codex', 'chatgpt')).toContain('codex login');
  });
});

describe('resolveModel', () => {
  it('prefers --model, then the configured model, then the agent default', () => {
    expect(resolveModel('codex', 'gpt-x', { agent: 'codex', model: 'configured' })).toBe('gpt-x');
    expect(resolveModel('codex', undefined, { agent: 'codex', model: 'configured' })).toBe('configured');
    expect(resolveModel('codex', undefined, { agent: 'codex' })).toBe(getDefaultModel('codex'));
  });

  it('ignores a configured model that was set for a different agent', () => {
    expect(resolveModel('codex', undefined, { agent: 'claude', model: 'claude-opus' })).toBe(getDefaultModel('codex'));
  });
});

describe('custom agent', () => {
  it('is supported but not offered by the interactive picker', () => {
    expect(isValidAgent('custom')).toBe(true);
    expect(resolveAgentSelection('5', 'claude')).toBe('claude');
    expect(resolveAgentSelection('custom', 'claude')).toBe('claude');
  });

  it('has no default model or API key of its own', () => {
    expect(getDefaultModel('custom')).toBe('');
    expect(getAgentEnvKey('custom')).toBe('');
  });

  it('takes its binary from the first word of the command', () => {
    expect(customCommandBinary('  copilot -p --model {model} ')).toBe('copilot');
    expect(customCommandBinary(undefined)).toBe('');
  });

  it('passes the command and error pattern to the engine only for the custom agent', () => {
    const config = { agent: 'custom', agentCommand: 'goose run -i {prompt_file}', agentErrorPattern: 'quota' };
    expect(customAgentEnv('custom', config)).toEqual({ AGENT_COMMAND: 'goose run -i {prompt_file}', AGENT_ERROR_PATTERN: 'quota' });
    expect(customAgentEnv('custom', { agent: 'custom', agentCommand: 'x' })).toEqual({ AGENT_COMMAND: 'x' });
    expect(customAgentEnv('claude', config)).toEqual({});
  });
});

describe('custom agent credentials', () => {
  it('copies the named variables that are set, and accepts only valid names', () => {
    process.env.CODE_EVOLVE_TEST_TOKEN = 'abc';
    try {
      const config = { agent: 'custom', agentCommand: 'x', agentEnvVars: ['CODE_EVOLVE_TEST_TOKEN', 'CODE_EVOLVE_UNSET_VAR'] };
      expect(customAgentEnv('custom', config)).toEqual({ AGENT_COMMAND: 'x', CODE_EVOLVE_TEST_TOKEN: 'abc' });
    } finally {
      delete process.env.CODE_EVOLVE_TEST_TOKEN;
    }
    expect(isEnvVarName('GEMINI_API_KEY')).toBe(true);
    expect(isEnvVarName('BAD-NAME')).toBe(false);
    expect(isEnvVarName('1ABC')).toBe(false);
    for (const reserved of ['MODEL', 'AGENT', 'AGENT_COMMAND', 'PATH', 'TIMEOUT', 'IFS', 'BASH_ENV', 'LD_PRELOAD', 'NODE_OPTIONS']) {
      expect(isEnvVarName(reserved)).toBe(false);
    }
    process.env.AGENT_COMMAND = 'planted';
    try {
      expect(customAgentEnv('custom', { agent: 'custom', agentCommand: 'cmd', agentEnvVars: ['AGENT_COMMAND'] })).toEqual({ AGENT_COMMAND: 'cmd' });
    } finally {
      delete process.env.AGENT_COMMAND;
    }
  });
});
