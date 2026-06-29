import { runCommand } from '../run';

describe('run --force help', () => {
  it('describes the sponsor bonus-run gate, not a nonexistent schedule gate', () => {
    const force = runCommand.options.find((o) => o.long === '--force');
    expect(force).toBeDefined();
    // schedule.json never gates runs (it's display-only); the only gate --force
    // bypasses is the sponsor bonus-run gate in evolve.sh.
    expect(force!.description.toLowerCase()).toContain('bonus-run');
    expect(force!.description.toLowerCase()).not.toContain('schedule');
  });
});
