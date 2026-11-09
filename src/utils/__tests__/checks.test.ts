import { checkDependencies, formatDependencyResults, isOnPath, runProcess } from '../checks';

describe('formatDependencyResults', () => {
  it('renders a check mark with version when found', () => {
    const out = formatDependencyResults([{ name: 'git', found: true, version: 'git 2.43' }]);
    expect(out).toContain('✓');
    expect(out).toContain('git');
    expect(out).toContain('(git 2.43)');
  });

  it('renders a cross and no parens when missing', () => {
    const out = formatDependencyResults([{ name: 'codex', found: false }]);
    expect(out).toContain('✗');
    expect(out).toContain('codex');
    expect(out).not.toContain('(');
  });

  it('joins multiple results on separate lines', () => {
    const out = formatDependencyResults([
      { name: 'a', found: true },
      { name: 'b', found: false },
    ]);
    expect(out.split('\n')).toHaveLength(2);
  });
});

describe('checkDependencies', () => {
  it('rejects an unknown agent without probing the toolchain', async () => {
    const { ok, results } = await checkDependencies('gpt');
    expect(ok).toBe(false);
    expect(results).toEqual([{ name: 'gpt', found: false }]);
  });

  it('probes python3, git, and the agent binary for a known agent', async () => {
    const { results } = await checkDependencies('codex');
    expect(results.map((r) => r.name)).toEqual(['python3', 'git', 'codex']);
    // `ok` reflects the host toolchain; assert the structure, not the host state.
    for (const r of results) expect(typeof r.found).toBe('boolean');
  });

  it('maps each agent to its own binary name', async () => {
    expect((await checkDependencies('claude')).results[2].name).toBe('claude');
    expect((await checkDependencies('ollama')).results[2].name).toBe('ollama');
    expect((await checkDependencies('opencode')).results[2].name).toBe('opencode');
  });
});

describe('isOnPath', () => {
  it('finds an executable on PATH and rejects a missing one', () => {
    expect(isOnPath('node')).toBe(true);
    expect(isOnPath('no-such-binary-code-evolve')).toBe(false);
  });
});

describe('runProcess', () => {
  it('resolves with exit status and stdout, and null when the command cannot start', async () => {
    expect(await runProcess(process.execPath, ['-e', 'process.stdout.write("hi"); process.exit(3)'])).toEqual({ status: 3, stdout: 'hi' });
    expect((await runProcess('no-such-binary-code-evolve', [])).status).toBeNull();
    expect((await runProcess(process.execPath, ['-e', 'setTimeout(() => {}, 300)'], 0)).status).toBe(0);
  });
});
