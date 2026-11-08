import { Command } from 'commander';
import { removeProjectCron } from '../utils/crontab';
import fs from 'fs';
import { evolveFile, isInitialized } from '../utils/paths';

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
    let removed: boolean;
    try {
      removed = removeProjectCron(projectDir);
    } catch (err) {
      console.error(`Could not update the crontab, so it was left unchanged: ${err instanceof Error ? err.message : String(err)}`);
      process.exit(1);
    }

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

