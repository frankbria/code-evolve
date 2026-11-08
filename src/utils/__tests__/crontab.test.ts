import { CRON_MARKER, cronEntryMarker, tableFromListing, withoutProjectEntry } from '../crontab';

// Only pure helpers are unit-tested here: jest gives each test file its own process.env, so a
// stub `crontab` on a test-set PATH is NOT what child_process runs; that would hit the real
// user crontab. The crontab I/O is covered by tests/test_crontab_preserve.sh in a real shell.
const projectEntry = (dir: string) => `0 */4 * * * cd "${dir}" && bash run.sh ${cronEntryMarker(dir)}`;

describe('withoutProjectEntry', () => {
  it('removes only the entry for the given project', () => {
    const table = ['MAILTO=me', projectEntry('/home/u/app'), '0 1 * * * backup', ''].join('\n');
    const result = withoutProjectEntry(table, '/home/u/app');
    expect(result.removed).toBe(true);
    expect(result.table).toBe(['MAILTO=me', '0 1 * * * backup', ''].join('\n'));
  });

  it('keeps a sibling project whose path starts with the same prefix', () => {
    const table = [projectEntry('/home/u/app'), projectEntry('/home/u/app2'), ''].join('\n');
    const result = withoutProjectEntry(table, '/home/u/app');
    expect(result.table).toBe([projectEntry('/home/u/app2'), ''].join('\n'));
  });

  it('reports nothing removed and leaves the table byte-identical when absent', () => {
    const table = 'SHELL=/bin/bash\n0 1 * * * echo "$HOME" `date` 100%\n';
    const result = withoutProjectEntry(table, '/home/u/app');
    expect(result).toEqual({ table, removed: false });
  });

  it('leaves runs of blank lines elsewhere in the table untouched', () => {
    const table = ['0 1 * * * a', '', '', '', '0 2 * * * b', projectEntry('/p'), ''].join('\n');
    expect(withoutProjectEntry(table, '/p').table).toBe(['0 1 * * * a', '', '', '', '0 2 * * * b', ''].join('\n'));
  });

  it('removes the entry of a project whose path ends in a space', () => {
    const table = [projectEntry('/tmp/app '), '0 1 * * * keep', ''].join('\n');
    expect(withoutProjectEntry(table, '/tmp/app ')).toEqual({ table: '0 1 * * * keep\n', removed: true });
  });

  it('marks entries with the shared marker', () => {
    expect(cronEntryMarker('/x')).toBe(`# ${CRON_MARKER}:/x`);
  });
});

describe('tableFromListing', () => {
  it('returns the listing on success', () => {
    expect(tableFromListing({ status: 0, stdout: '0 1 * * * a\n', stderr: '' })).toBe('0 1 * * * a\n');
  });

  it('treats "no crontab for <user>" as an empty table', () => {
    expect(tableFromListing({ status: 1, stdout: '', stderr: 'no crontab for frank\n' })).toBe('');
  });

  it('throws on any other failure instead of reporting an empty table', () => {
    expect(() => tableFromListing({ status: 1, stdout: '', stderr: 'crontab: permission denied\n' })).toThrow(
      'crontab -l failed (exit 1): crontab: permission denied'
    );
    expect(() => tableFromListing({ status: null, stdout: '', stderr: '', error: new Error('spawn crontab ENOENT') })).toThrow(
      'Could not run crontab: spawn crontab ENOENT'
    );
  });
});
