import { engineLine } from '../status';

describe('engineLine', () => {
  it('reports the local schedule when one is installed, whatever the mode', () => {
    expect(engineLine({ every: 6, model: 'claude-sonnet-4-6' }, 'native')).toBe('every 6h (claude-sonnet-4-6)');
  });

  it('says the agent runs the schedule in native mode, where code-evolve has none to show', () => {
    const line = engineLine(null, 'native');
    expect(line).toContain("agent's own scheduler");
    expect(line).not.toContain('code-evolve start');
  });

  it('points to start when nothing schedules cycles', () => {
    expect(engineLine(null, 'local')).toBe('not scheduled (run: code-evolve start)');
    expect(engineLine(null, null)).toBe('not scheduled (run: code-evolve start)');
  });
});
