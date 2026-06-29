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
    expect(getExecutionModes()).toEqual(['local', 'ci', 'both']);
    for (const m of getExecutionModes()) expect(isValidMode(m)).toBe(true);
    expect(isValidMode('cloud')).toBe(false);
  });
});

describe('resolveModeSelection', () => {
  it('maps 1-based index, name, and skip/empty', () => {
    expect(resolveModeSelection('1')).toBe('local');
    expect(resolveModeSelection('2')).toBe('ci');
    expect(resolveModeSelection('3')).toBe('both');
    expect(resolveModeSelection('ci')).toBe('ci');
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
