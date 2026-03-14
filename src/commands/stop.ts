import { Command } from 'commander';
import { execSync } from 'child_process';
import fs from 'fs';
import { evolveFile, isInitialized } from '../utils/paths';

const CRON_MARKER = 'code-evolve';

export const stopCommand = new Command('stop')
  .description('Stop the evolution engine (removes the local cron job)')
  .action(async () => {
    if (!isInitialized()) {
      console.error('Not initialized — nothing to stop.');
      process.exit(1);
    }

    if (process.platform === 'win32') {
      console.error('Local scheduling on native Windows is not supported.');
      process.exit(1);
    }

    const projectDir = process.cwd();
    const removed = removeExistingCron(projectDir);

    if (removed) {
      console.log('Evolution engine stopped. Cron job removed.');
    } else {
      console.log('No active cron job found for this project.');
    }

    // Remove schedule config
    const schedulePath = evolveFile('schedule.json');
    if (fs.existsSync(schedulePath)) {
      fs.unlinkSync(schedulePath);
    }
  });

function getCrontab(): string {
  try {
    return execSync('crontab -l 2>/dev/null', { encoding: 'utf8' });
  } catch {
    return '';
  }
}

function setCrontab(content: string): void {
  execSync(`echo ${JSON.stringify(content)} | crontab -`, { encoding: 'utf8' });
}

function removeExistingCron(projectDir: string): boolean {
  const existing = getCrontab();
  if (!existing) return false;

  const marker = `${CRON_MARKER}:${projectDir}`;
  const lines = existing.split('\n');
  const filtered = lines.filter((line) => !line.includes(marker));

  if (filtered.length === lines.length) return false;

  const cleaned = filtered.join('\n').replace(/\n{3,}/g, '\n\n');
  setCrontab(cleaned);
  return true;
}
