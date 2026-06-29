import { checkDependencies, formatDependencyResults } from '../checks';

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
  it('rejects an unknown agent without probing the toolchain', () => {
    const { ok, results } = checkDependencies('gpt');
    expect(ok).toBe(false);
    expect(results).toEqual([{ name: 'gpt', found: false }]);
  });

  it('probes python3, git, and the agent binary for a known agent', () => {
    const { results } = checkDependencies('codex');
    expect(results.map((r) => r.name)).toEqual(['python3', 'git', 'codex']);
    // `ok` reflects the host toolchain; assert the structure, not the host state.
    for (const r of results) expect(typeof r.found).toBe('boolean');
  });

  it('maps each agent to its own binary name', () => {
    expect(checkDependencies('claude').results[2].name).toBe('claude');
    expect(checkDependencies('ollama').results[2].name).toBe('ollama');
    expect(checkDependencies('opencode').results[2].name).toBe('opencode');
  });
});
