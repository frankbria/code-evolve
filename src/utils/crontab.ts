import { execFileSync } from 'child_process';

export const CRON_MARKER = 'code-evolve';

/** The trailing comment that identifies a project's cron entry. */
export function cronEntryMarker(projectDir: string): string {
  return `# ${CRON_MARKER}:${projectDir}`;
}

export function getCrontab(): string {
  try {
    return execFileSync('crontab', ['-l'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return '';
  }
}

/** Installs `table` without a shell, so `$`, backticks and `%` in other entries stay literal. */
export function setCrontab(table: string): void {
  const content = table.endsWith('\n') ? table : `${table}\n`;
  execFileSync('crontab', ['-'], { input: content, stdio: ['pipe', 'ignore', 'pipe'] });
}

/** Drops the project's entry; the end-of-line match keeps `/app2` when removing `/app`. */
export function withoutProjectEntry(table: string, projectDir: string): { table: string; removed: boolean } {
  const marker = cronEntryMarker(projectDir);
  const lines = table.split('\n');
  const kept = lines.filter((line) => !line.trimEnd().endsWith(marker));
  if (kept.length === lines.length) return { table, removed: false };
  return { table: kept.join('\n').replace(/\n{3,}/g, '\n\n'), removed: true };
}

export function removeProjectCron(projectDir: string): boolean {
  const { table, removed } = withoutProjectEntry(getCrontab(), projectDir);
  if (removed) setCrontab(table);
  return removed;
}
