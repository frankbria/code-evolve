import { execFileSync, spawnSync } from 'child_process';

export const CRON_MARKER = 'code-evolve';

/** The trailing comment that identifies a project's cron entry. */
export function cronEntryMarker(projectDir: string): string {
  return `# ${CRON_MARKER}:${projectDir}`;
}

export interface CrontabListing {
  status: number | null;
  stdout: string;
  stderr: string;
  error?: Error;
}

/**
 * Interprets `crontab -l`. Only "no crontab for <user>" means empty; any other failure throws,
 * because treating it as empty would make the next write erase the user's whole schedule.
 */
export function tableFromListing(listing: CrontabListing): string {
  if (listing.error) throw new Error(`Could not run crontab: ${listing.error.message}`);
  if (listing.status === 0) return listing.stdout;
  if (/no crontab for/i.test(listing.stderr)) return '';
  throw new Error(`crontab -l failed (exit ${listing.status}): ${listing.stderr.trim()}`);
}

export function getCrontab(): string {
  // LC_ALL=C keeps the "no crontab for" message in English for tableFromListing.
  const result = spawnSync('crontab', ['-l'], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } });
  return tableFromListing({ status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '', error: result.error });
}

/** Installs `table` without a shell, so `$`, backticks and `%` in other entries stay literal. */
export function setCrontab(table: string): void {
  // crontab(1) rejects a final line without a newline.
  const content = table.endsWith('\n') ? table : `${table}\n`;
  execFileSync('crontab', ['-'], { input: content, stdio: ['pipe', 'ignore', 'pipe'] });
}

/** Drops the project's entry and nothing else; the end-of-line match keeps `/app2` when removing `/app`. */
export function withoutProjectEntry(table: string, projectDir: string): { table: string; removed: boolean } {
  const marker = cronEntryMarker(projectDir);
  const lines = table.split('\n');
  const kept = lines.filter((line) => !line.endsWith(marker));
  if (kept.length === lines.length) return { table, removed: false };
  return { table: kept.join('\n'), removed: true };
}

export function removeProjectCron(projectDir: string): boolean {
  const { table, removed } = withoutProjectEntry(getCrontab(), projectDir);
  if (removed) setCrontab(table);
  return removed;
}
