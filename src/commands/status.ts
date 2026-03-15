import { Command } from 'commander';
import fs from 'fs';
import { evolveFile, isInitialized } from '../utils/paths';
import { output } from '../utils/output';

export const statusCommand = new Command('status')
  .description('Show current evolution state')
  .action(async () => {
    if (!isInitialized()) {
      console.error('Not initialized. Run `code-evolve init` first.');
      process.exit(1);
    }

    // Read day count
    let dayCount = 0;
    try {
      dayCount = parseInt(fs.readFileSync(evolveFile('DAY_COUNT'), 'utf8').trim(), 10) || 0;
    } catch {
      // DAY_COUNT doesn't exist yet
    }

    // Read birth date
    let birthDate = 'unknown';
    try {
      birthDate = fs.readFileSync(evolveFile('.birth_date'), 'utf8').trim();
    } catch {
      // .birth_date doesn't exist yet
    }

    // Parse spec progress
    let total = 0;
    let done = 0;
    let partial = 0;
    try {
      const spec = fs.readFileSync(evolveFile('spec.md'), 'utf8');
      // Strip HTML comments before counting checkboxes
      const stripped = spec.replace(/<!--[\s\S]*?-->/g, '');
      const lines = stripped.split('\n');
      for (const line of lines) {
        if (/^[\s]*- \[[ x~]\]/.test(line)) {
          total++;
          if (/^[\s]*- \[x\]/.test(line)) done++;
          else if (/^[\s]*- \[~\]/.test(line)) partial++;
        }
      }
    } catch {
      // spec.md doesn't exist
    }

    // Parse last journal entry
    let lastEntry = '';
    try {
      const journal = fs.readFileSync(evolveFile('JOURNAL.md'), 'utf8');
      const match = journal.match(/^## Day .+$/m);
      if (match) {
        const startIdx = journal.indexOf(match[0]);
        const nextEntry = journal.indexOf('\n## Day ', startIdx + 1);
        const endIdx = nextEntry === -1 ? undefined : nextEntry;
        lastEntry = journal.slice(startIdx, endIdx).trim();
      }
    } catch {
      // JOURNAL.md doesn't exist
    }

    // Check schedule
    let schedule: { every?: number; model?: string; started?: string } | null = null;
    try {
      schedule = JSON.parse(fs.readFileSync(evolveFile('schedule.json'), 'utf8'));
    } catch {
      // not scheduled
    }

    const data = {
      day: dayCount,
      started: birthDate,
      features: { total, done, partial, remaining: total - done - partial },
      schedule: schedule ? { every: `${schedule.every}h`, model: schedule.model } : null,
      lastEntry,
    };

    const remaining = total - done - partial;
    const progressLine = total > 0
      ? `${done}/${total} features done${partial > 0 ? ` (${partial} in progress)` : ''}${remaining > 0 ? `, ${remaining} remaining` : ''}`
      : 'No features defined in .evolve/spec.md yet';

    const scheduleLine = schedule
      ? `every ${schedule.every}h (${schedule.model})`
      : 'not scheduled (run: code-evolve start)';

    const humanReadable = [
      `code-evolve status`,
      `  Day:      ${dayCount}`,
      `  Started:  ${birthDate}`,
      `  Progress: ${progressLine}`,
      `  Engine:   ${scheduleLine}`,
      lastEntry ? `\n  Last entry:\n  ${lastEntry.split('\n').join('\n  ')}` : '',
    ]
      .filter(Boolean)
      .join('\n');

    output(data, humanReadable);
  });
